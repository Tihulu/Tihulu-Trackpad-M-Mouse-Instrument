package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class MobileLanSocketRequestTest {
    @Test fun exactOriginAndProtocolWithoutSecret(){
        val endpoint=MobileLanEndpoint.parse("https://192.168.1.25:9444/")!!
        val request=MobileLanSocket.request(endpoint)
        // OkHttp converts wss to https for the upgrade.
        assertEquals("https://192.168.1.25:9443/",request.url.toString())
        assertEquals("https://192.168.1.25:9444",request.header("Origin"))
        assertEquals("tihulu-touch-v1",request.header("Sec-WebSocket-Protocol"))
        assertNull(request.header("Authorization"));assertNull(request.url.query)
        assertEquals("GET",request.method)
    }
}
