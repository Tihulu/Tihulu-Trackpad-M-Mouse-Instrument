package com.tihulu.mobile.air

import java.io.ByteArrayInputStream
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import org.junit.Assert.*
import org.junit.Test

/** Real JVM TLS handshake and HTTP upgrade on an ephemeral loopback
 * listener. Production endpoint parsing still rejects loopback; the
 * fixture supplies the already-connected raw socket to the same TLS path.
 * Disposable keys are generated in a temporary directory, never shipped. */
class BoundedLanTlsLoopbackTest {
    private val password="fixture-only-password"
    private fun keytool(dir:File,vararg args:String) {
        val tool=File(System.getProperty("java.home"),"bin/keytool")
        val log=File(dir,"keytool.log")
        val p=ProcessBuilder(listOf(tool.absolutePath)+args.toList()).directory(dir)
            .redirectErrorStream(true).redirectOutput(log).start()
        if(!p.waitFor(30,TimeUnit.SECONDS)){p.destroyForcibly();error("Fixture keytool timeout")}
        check(p.exitValue()==0){log.readText().take(2048)}
    }
    @Test fun realTlsExactIpTrustAndUpgrade() {
        val dir=Files.createTempDirectory("tihulu-tls-test").toFile()
        try {
            keytool(dir,"-genkeypair","-alias","root","-keyalg","RSA","-keysize","2048",
                "-dname","CN=TIHULU temporary test root","-validity","30","-ext","BC=ca:true",
                "-ext","KU=keyCertSign,cRLSign","-keystore","root.p12","-storetype","PKCS12",
                "-storepass",password,"-keypass",password,"-noprompt")
            keytool(dir,"-exportcert","-alias","root","-keystore","root.p12","-storepass",password,"-file","root.der")
            keytool(dir,"-genkeypair","-alias","server","-keyalg","RSA","-keysize","2048",
                "-dname","CN=192.168.1.25","-validity","30","-keystore","server.p12",
                "-storetype","PKCS12","-storepass",password,"-keypass",password,"-noprompt")
            keytool(dir,"-certreq","-alias","server","-keystore","server.p12","-storepass",password,"-file","server.csr")
            keytool(dir,"-gencert","-alias","root","-keystore","root.p12","-storepass",password,
                "-infile","server.csr","-outfile","server.der","-validity","15",
                "-ext","SAN=ip:192.168.1.25","-ext","KU=digitalSignature,keyEncipherment","-ext","EKU=serverAuth")
            keytool(dir,"-importcert","-alias","root","-keystore","server.p12","-storepass",password,"-file","root.der","-noprompt")
            keytool(dir,"-importcert","-alias","server","-keystore","server.p12","-storepass",password,"-file","server.der","-noprompt")
            val store=KeyStore.getInstance("PKCS12")
            File(dir,"server.p12").inputStream().use{store.load(it,password.toCharArray())}
            val keys=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
            keys.init(store,password.toCharArray())
            val server=SSLContext.getInstance("TLS").apply{init(keys.keyManagers,null,null)}
            val root=File(dir,"root.der").readBytes()
            val fingerprint=MessageDigest.getInstance("SHA-256").digest(root).joinToString(""){"%02x".format(it.toInt() and 255)}
            val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
            val other=MobileLanEndpoint.parse("https://192.168.1.26:9444/")!!
            val trusted=checkNotNull(MobileLanTrust.verifiedRoot(endpoint,root,fingerprint))
            val wrongHost=checkNotNull(MobileLanTrust.verifiedRoot(other,root,fingerprint))
            exchange(server,endpoint,trusted.socketFactory(),true,false)
            exchange(server,other,wrongHost.socketFactory(),false,false)
            val system=SSLContext.getInstance("TLS").apply{init(null,null,null)}.socketFactory
            exchange(server,endpoint,system,false,false)
            exchange(server,endpoint,trusted.socketFactory(),false,true)
        }finally{dir.deleteRecursively()}
    }
    private fun exchange(context:SSLContext,endpoint:MobileLanEndpoint,
        factory:javax.net.ssl.SSLSocketFactory,expected:Boolean,badUpgrade:Boolean) {
        val loopback=InetAddress.getByAddress(byteArrayOf(127,0,0,1))
        val listener=context.serverSocketFactory.createServerSocket(0,1,loopback) as SSLServerSocket
        listener.soTimeout=5000
        val executor=Executors.newSingleThreadExecutor()
        val result=executor.submit<Boolean> {
            try {
                (listener.accept() as SSLSocket).use { peer ->
                    peer.soTimeout=5000
                    peer.startHandshake()
                    val input=peer.inputStream
                    val request=StringBuilder()
                    while(!request.endsWith("\r\n\r\n")) {
                        check(request.length<4096)
                        val b=input.read();check(b>=0);request.append(b.toChar())
                    }
                    val headers=request.toString().split("\r\n")
                    check(headers[0]=="GET / HTTP/1.1")
                    check(headers.contains("Host: "+endpoint.host+":9443"))
                    check(headers.contains("Origin: "+endpoint.origin))
                    check(headers.none{it.startsWith("Authorization:")||it.startsWith("Cookie:")})
                    val key=headers.single{it.startsWith("Sec-WebSocket-Key: ")}.substringAfter(": ")
                    val accept=Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1")
                        .digest((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray(Charsets.US_ASCII)))
                    val response="HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
                        "Sec-WebSocket-Accept: "+(if(badUpgrade)"wrong" else accept)+"\r\nSec-WebSocket-Protocol: tihulu-touch-v1\r\n\r\n"
                    peer.outputStream.write(response.toByteArray(Charsets.US_ASCII)+byteArrayOf(129.toByte(),2,111,107))
                    peer.outputStream.flush()
                    true
                }
            }catch(_:Exception){false}
        }
        val owner=LanConnectionOwner()
        try {
            assertTrue(owner.begin())
            val raw=Socket()
            assertTrue(owner.installRaw(raw))
            raw.connect(InetSocketAddress(loopback,listener.localPort),3000)
            val opened=runCatching{BoundedLanTlsChannel.upgradeConnected(raw,endpoint,factory,owner)}
            assertEquals("TLS / Upgrade result",expected,opened.isSuccess)
            if(expected)assertEquals(BoundedLanFrameReader.Event.Text("ok"),BoundedLanFrameReader(opened.getOrThrow().input).next())
        }finally{
            owner.close();listener.close()
            try {if(expected)assertTrue(result.get(6,TimeUnit.SECONDS)) else result.get(6,TimeUnit.SECONDS)}
            finally{executor.shutdownNow()}
        }
    }
}
