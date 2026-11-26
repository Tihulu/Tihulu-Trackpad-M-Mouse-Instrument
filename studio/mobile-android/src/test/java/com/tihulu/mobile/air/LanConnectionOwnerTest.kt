package com.tihulu.mobile.air

import java.io.Closeable
import java.io.IOException
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import org.junit.Assert.*
import org.junit.Test

class LanConnectionOwnerTest {
    private class Handle(private val name:String,private val log:MutableList<String>,
        private val throwsOnClose:Boolean=false):Closeable {
        override fun close(){log.add(name);if(throwsOnClose)throw IOException("fixture")}
    }
    @Test fun closeRetiresRawBeforeTlsAndIsIdempotent() {
        val log=mutableListOf<String>();val owner=LanConnectionOwner()
        assertTrue(owner.begin());assertFalse(owner.begin())
        assertTrue(owner.installRaw(Handle("raw",log)))
        assertTrue(owner.installTLS(Handle("tls",log)))
        owner.close();owner.close()
        assertEquals(listOf("raw","tls"),log)
        assertTrue(runCatching{owner.requireOpen()}.isFailure)
        assertFalse(owner.begin())
    }
    @Test fun stoppedBeforeInstallClosesLateHandle() {
        val log=mutableListOf<String>();val owner=LanConnectionOwner()
        owner.begin();owner.close()
        assertFalse(owner.installRaw(Handle("late",log)))
        assertFalse(owner.installTLS(Handle("lateTLS",log)))
        assertEquals(listOf("late","lateTLS"),log)
    }
    @Test fun cancellationBetweenRawAndTlsClosesBoth() {
        val log=mutableListOf<String>();val owner=LanConnectionOwner()
        owner.begin();owner.installRaw(Handle("raw",log));owner.close()
        assertFalse(owner.installTLS(Handle("lateTLS",log)))
        assertEquals(listOf("raw","lateTLS"),log)
    }
    @Test fun rawCloseFailureStillClosesTls() {
        val log=mutableListOf<String>();val owner=LanConnectionOwner()
        owner.begin();owner.installRaw(Handle("raw",log,true));owner.installTLS(Handle("tls",log))
        owner.close()
        assertEquals(listOf("raw","tls"),log)
    }
    @Test fun cannotReplaceOwnedSocket() {
        val log=mutableListOf<String>();val owner=LanConnectionOwner()
        owner.begin();owner.installRaw(Handle("raw",log))
        assertFalse(owner.installRaw(Handle("replacement",log)))
        owner.installTLS(Handle("tls",log))
        assertFalse(owner.installTLS(Handle("replacementTLS",log)))
        owner.close()
        assertEquals(listOf("replacement","replacementTLS","raw","tls"),log)
    }
    @Test fun numericAddressAndPlatformTlsPolicy() {
        val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
        assertArrayEquals(byteArrayOf(192.toByte(),168.toByte(),1,25),BoundedLanTlsChannel.numericAddress(endpoint).address)
        val factory=SSLContext.getInstance("TLS").apply {init(null,null,null)}.socketFactory
        (factory.createSocket() as SSLSocket).use { socket ->
            BoundedLanTlsChannel.configure(socket)
            assertTrue(socket.useClientMode)
            assertEquals("HTTPS",socket.sslParameters.endpointIdentificationAlgorithm)
            assertTrue(socket.enabledProtocols.isNotEmpty())
            assertTrue(socket.enabledProtocols.all {it=="TLSv1.2"||it=="TLSv1.3"})
        }
    }
    @Test fun stoppedChannelCannotOpenNetwork() {
        val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
        val channel=BoundedLanTlsChannel(endpoint)
        channel.close()
        assertTrue(runCatching{channel.open()}.exceptionOrNull() is IOException)
    }
}
