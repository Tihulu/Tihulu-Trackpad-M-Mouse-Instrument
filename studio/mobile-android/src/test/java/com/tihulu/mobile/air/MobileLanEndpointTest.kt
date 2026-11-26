package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test

class MobileLanEndpointTest {
    @Test fun canonicalPrivateQrAddress(){
        for(host in listOf("10.0.0.2","172.16.1.3","172.31.255.254","192.168.1.25")){
            val e=MobileLanEndpoint.parse("https://$host:9444/")!!
            assertEquals("wss://$host:9443/",e.socketUrl)
            assertEquals("https://$host:9444",e.origin)
            assertEquals("tihulu-touch-v1",e.subprotocol)
        }
    }
    @Test fun invalidAuthorityAndSecretInUrl(){
        for(input in listOf("https://127.0.0.1:9444/","http://192.168.1.25:9444/","https://192.168.01.25:9444/",
            "https://192.168.1.25:9444/?token=abc","https://192.168.1.25:9444/#abc",
            "https://192.168.1.25:9444","https://192.168.1.25:9443/","https://8.8.8.8:9444/",
            "https://192.168.1.25.evil.test:9444/","https://u@192.168.1.25:9444/",
            "https://172.32.0.1:9444/","https://[::1]:9444/"," https://192.168.1.25:9444/")){
            assertNull(input,MobileLanEndpoint.parse(input))
        }
    }
    @Test fun exactBinaryInvitation(){
        val token="aB".repeat(32)
        assertArrayEquals(ByteArray(32){0xab.toByte()},MobileLanEndpoint.invitationBytes(token))
        for(bad in listOf(token+" ",token.dropLast(1),"g".repeat(64),"https://"+token,"é".repeat(32)))assertNull(MobileLanEndpoint.invitationBytes(bad))
    }
}
