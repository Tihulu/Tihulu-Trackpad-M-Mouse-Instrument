package com.tihulu.mobile.air

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class BoundedLanUpgradeTest {
    private val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
    private fun upgrade()=BoundedLanUpgrade.fromNonce(endpoint,"the sample nonce".toByteArray())
    private val key="dGhlIHNhbXBsZSBub25jZQ=="
    private val digest="s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    private val good="HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+digest+"\r\nSec-WebSocket-Protocol: tihulu-touch-v1\r\n\r\n"
    private fun rejected(response:String) {
        val u=upgrade();u.request()
        assertTrue(runCatching {u.accept(ByteArrayInputStream(response.toByteArray()))}.exceptionOrNull() is IOException)
        assertTrue(runCatching {u.accept(ByteArrayInputStream(good.toByteArray()))}.isFailure)
    }
    @Test fun exactEndpointNonceAndFrameBoundary() {
        val u=upgrade()
        val request=u.request().toString(Charsets.US_ASCII)
        assertTrue(request.startsWith("GET / HTTP/1.1\r\nHost: 192.168.1.25:9443\r\n"))
        assertTrue(request.contains("Origin: https://192.168.1.25:9444\r\n"))
        assertTrue(request.contains("Sec-WebSocket-Key: "+key+"\r\n"))
        assertFalse(request.contains("Authorization:",ignoreCase=true))
        val stream=ByteArrayInputStream(good.toByteArray()+byteArrayOf(129.toByte(),0))
        u.accept(stream)
        assertEquals(2,stream.available())
        assertEquals(BoundedLanFrameReader.Event.Text(""),BoundedLanFrameReader(stream).next())
    }
    @Test fun wrongStatusDigestAndProtocolRejected() {
        for(value in listOf(good.replace("101 Switching Protocols","302 Found"),
            good.replace(digest,"wrong"),good.replace("tihulu-touch-v1","other"),
            good.replace("Connection: Upgrade","Connection: close, Upgrade"),
            good.replace("Upgrade: websocket","Upgrade: h2c"),
            good.replace("HTTP/1.1","HTTP/1.0")))rejected(value)
    }
    @Test fun duplicatesExtensionsAndBodyRejected() {
        for(extra in listOf("Sec-WebSocket-Protocol: tihulu-touch-v1","sec-websocket-accept: "+digest,
            "Sec-WebSocket-Extensions: permessage-deflate","Content-Length: 0",
            "Transfer-Encoding: chunked"," Upgrade: websocket","Bad Header: value")) {
            rejected(good.dropLast(2)+extra+"\r\n\r\n")
        }
    }
    @Test fun boundsAndStrictCrLf() {
        rejected(good.dropLast(2)+"X-Large: "+"a".repeat(4096)+"\r\n\r\n")
        rejected(good.dropLast(2)+(0..32).joinToString(""){"X-$it: ok\r\n"}+"\r\n")
        rejected(good.replace("\r\n","\n"))
        rejected(good.dropLast(1))
    }
    @Test fun oneShotAndFreshKeys() {
        val u=upgrade()
        assertTrue(runCatching {u.accept(ByteArrayInputStream(good.toByteArray()))}.isFailure)
        u.request();u.accept(ByteArrayInputStream(good.toByteArray()))
        assertTrue(runCatching {u.request()}.isFailure)
        assertTrue(runCatching {u.accept(ByteArrayInputStream(good.toByteArray()))}.isFailure)
        assertFalse(BoundedLanUpgrade.create(endpoint).request().contentEquals(BoundedLanUpgrade.create(endpoint).request()))
    }
}
