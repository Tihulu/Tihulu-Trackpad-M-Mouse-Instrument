package com.tihulu.mobile.air

import okhttp3.OkHttpClient
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Single-host, in-memory private CA provisioning. The caller must obtain
 * the expected SHA-256 via a separately authenticated channel, not from
 * the certificate file, QR, or the unauthenticated network peer.
 * No global CA installation, trust-all verifier or hostname override.
 * This is not a UI/import flow; network permission remains disabled.
 */
class MobileLanTrust private constructor(val host:String, internal val manager:X509TrustManager) {
    internal fun socketFactory():javax.net.ssl.SSLSocketFactory {
        val context=SSLContext.getInstance("TLS")
        context.init(null,arrayOf(manager),null)
        return context.socketFactory
    }
    internal fun configure(builder:OkHttpClient.Builder) {
        builder.sslSocketFactory(socketFactory(),manager)
        // Keep OkHttp's default hostname verifier. In particular the
        // server leaf must carry the numeric IP as an IP SAN.
    }

    companion object {
        const val MAX_CERTIFICATE_BYTES=16_384
        /** Reads at most limit+1 bytes. Caller owns and closes the input. */
        fun readDer(input:InputStream):ByteArray {
            // InputStream.readNBytes is not available on all API 26 devices.
            val buffer=ByteArray(MAX_CERTIFICATE_BYTES+1)
            var size=0
            while(size<buffer.size) {
                val count=input.read(buffer,size,buffer.size-size)
                if(count<0)break
                require(count>0)
                size+=count
            }
            require(size in 1..MAX_CERTIFICATE_BYTES)
            return buffer.copyOf(size)
        }

        fun verifiedRoot(endpoint:MobileLanEndpoint,der:ByteArray,expectedSha256:String):MobileLanTrust? {
            if(der.isEmpty()||der.size>MAX_CERTIFICATE_BYTES||expectedSha256.length!=64)return null
            val expected=MobileLanEndpoint.invitationBytes(expectedSha256)?:return null
            val copy=der.copyOf()
            return try {
                val actual=MessageDigest.getInstance("SHA-256").digest(copy)
                if(!MessageDigest.isEqual(actual,expected))return null
                val input=ByteArrayInputStream(copy)
                val cert=CertificateFactory.getInstance("X.509").generateCertificate(input) as? X509Certificate ?:return null
                // Exact single canonical DER certificate; no PEM bundle,
                // trailing bytes or private key container.
                if(input.available()!=0||!MessageDigest.isEqual(cert.encoded,copy))return null
                if(cert.basicConstraints<0||cert.subjectX500Principal!=cert.issuerX500Principal)return null
                val usage=cert.keyUsage
                if(usage!=null&&(usage.size<=5||!usage[5]))return null
                cert.checkValidity()
                cert.verify(cert.publicKey)
                val store=KeyStore.getInstance(KeyStore.getDefaultType())
                store.load(null,null)
                store.setCertificateEntry("verified-private-root",cert)
                val factory=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                factory.init(store)
                val manager=factory.trustManagers.filterIsInstance<X509TrustManager>().singleOrNull()?:return null
                MobileLanTrust(endpoint.host,manager)
            }catch(_:Exception){null}
        }
    }
}
