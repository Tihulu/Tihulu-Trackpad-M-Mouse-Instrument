package com.tihulu.mobile.air

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocket

/**
 * Isolated direct TLS/HTTP upgrade channel candidate. It owns exactly
 * one private numeric endpoint; no DNS, proxies, redirect or retries.
 * Standard platform chain and HTTPS endpoint identification are required;
 * also insist on an exact IPv4 SAN. No trust-all fallback.
 * Caller must run an independent absolute five-second setup watchdog
 * and interrupt blocked reads/writes with close(). Not yet wired to UI.
 */
internal class BoundedLanTlsChannel(private val endpoint:MobileLanEndpoint,
    private val privateRoot:MobileLanTrust?=null):Closeable {
    init {require(privateRoot==null||privateRoot.host==endpoint.host)}
    data class Streams(val input:InputStream,val output:OutputStream)
    private val owner=LanConnectionOwner()
    override fun close()=owner.close()

    fun open():Streams {
        if(!owner.begin())throw IOException("LAN channel is single use")
        try {
            val raw=Socket(Proxy.NO_PROXY)
            if(!owner.installRaw(raw))throw IOException("LAN channel retired")
            raw.soTimeout=5000
            raw.tcpNoDelay=true
            val address=numericAddress(endpoint)
            raw.connect(InetSocketAddress(address,9443),5000)
            owner.requireOpen()
            val factory=privateRoot?.socketFactory()
                ?:SSLContext.getInstance("TLS").apply {init(null,null,null)}.socketFactory
            val secure=factory.createSocket(raw,endpoint.host,9443,true)
            if(secure !is SSLSocket) {
                secure.close()
                throw IOException("TLS socket unavailable")
            }
            if(!owner.installTLS(secure))throw IOException("LAN channel retired")
            configure(secure)
            secure.soTimeout=5000
            secure.startHandshake()
            owner.requireOpen()
            val leaf=secure.session.peerCertificates.firstOrNull() as? X509Certificate
                ?:throw SSLPeerUnverifiedException("Missing server certificate")
            if(!hasExactIpSan(leaf,endpoint))throw SSLPeerUnverifiedException("Missing exact IP SAN")
            val input=secure.inputStream
            val output=secure.outputStream
            val upgrade=BoundedLanUpgrade.create(endpoint)
            output.write(upgrade.request());output.flush()
            upgrade.accept(input)
            owner.requireOpen()
            // In READY the independent owner watchdog is authoritative.
            secure.soTimeout=0
            return Streams(input,output)
        }catch(e:Exception){
            owner.close()
            throw e
        }
    }
    companion object {
        internal fun numericAddress(endpoint:MobileLanEndpoint):InetAddress =
            InetAddress.getByAddress(endpoint.host.split('.').map{it.toInt().toByte()}.toByteArray())
        internal fun configure(socket:SSLSocket) {
            socket.useClientMode=true
            val protocols=socket.supportedProtocols.filter{it=="TLSv1.2"||it=="TLSv1.3"}
            if(protocols.isEmpty())throw IOException("Modern TLS unavailable")
            socket.enabledProtocols=protocols.toTypedArray()
            val parameters=socket.sslParameters
            parameters.endpointIdentificationAlgorithm="HTTPS"
            socket.sslParameters=parameters
            if(socket.sslParameters.endpointIdentificationAlgorithm!="HTTPS")
                throw IOException("TLS endpoint verification unavailable")
        }
        internal fun hasExactIpSan(cert:X509Certificate,endpoint:MobileLanEndpoint):Boolean {
            return cert.subjectAlternativeNames?.any { row ->
                row.size>=2&&row[0]==7&&row[1]==endpoint.host
            }==true
        }
    }
}
