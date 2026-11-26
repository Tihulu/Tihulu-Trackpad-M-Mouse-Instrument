package com.tihulu.mobile.air
import java.io.ByteArrayInputStream
import org.junit.Assert.*
import org.junit.Test
class LocalHandModelTest {
    @Test fun hashAndFreshDirectBuffer() {
        val model=LocalHandModel.read(ByteArrayInputStream("abc".toByteArray()),3)
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",model.sha256)
        val first=model.directBuffer();assertTrue(first.isDirect);assertEquals(97,first.get().toInt())
        first.put(0,0.toByte())
        assertEquals(97,model.directBuffer().get().toInt())
    }
    @Test fun emptyAndOversizedModelRejected() {
        for(bytes in listOf(byteArrayOf(),byteArrayOf(1,2,3,4))) {
            try {LocalHandModel.read(ByteArrayInputStream(bytes),3);fail("invalid model accepted")}
            catch(_:IllegalArgumentException){}
        }
    }
}
