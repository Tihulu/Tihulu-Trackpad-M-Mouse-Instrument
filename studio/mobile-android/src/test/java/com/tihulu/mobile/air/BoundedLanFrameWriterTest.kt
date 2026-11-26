package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class BoundedLanFrameWriterTest {
    private val mask=byteArrayOf(0x12,0x34,0x56,0x78)
    private val writer=BoundedLanFrameWriter.testing {mask.copyInto(it)}
    private fun verify(frame:ByteArray,opcode:Int,expected:ByteArray) {
        assertEquals(128 or opcode,frame[0].toInt() and 255)
        val n=frame[1].toInt() and 255
        assertTrue(n and 128 != 0)
        val header=if(expected.size<=125)2 else 4
        assertEquals(if(header==2)expected.size else 126,n and 127)
        if(header==4)assertEquals(expected.size,((frame[2].toInt() and 255) shl 8) or (frame[3].toInt() and 255))
        assertEquals(header+4+expected.size,frame.size)
        assertArrayEquals(mask,frame.copyOfRange(header,header+4))
        assertArrayEquals(expected,ByteArray(expected.size){i->
            (frame[header+4+i].toInt() xor frame[header+i%4].toInt()).toByte()
        })
    }
    @Test fun invitationIsMaskedAndInputUnchanged() {
        val token=ByteArray(32){it.toByte()}
        val before=token.copyOf()
        val frame=writer.invitation(token)
        verify(frame,2,before)
        assertArrayEquals(before,token)
        assertFalse(frame.copyOfRange(6,frame.size).contentEquals(before))
    }
    @Test fun textBoundaryUsesCanonicalLength() {
        for(length in listOf(1,125,126,255,256)) {
            val text=ByteArray(length){65}
            verify(writer.text(text),1,text)
        }
    }
    @Test fun controlFramesAreMaskedAndBounded() {
        verify(writer.pong(byteArrayOf()),10,byteArrayOf())
        val data=ByteArray(125){it.toByte()}
        verify(writer.pong(data),10,data)
        assertTrue(runCatching{writer.pong(ByteArray(126))}.isFailure)
    }
    @Test fun rejectsInvalidPayloadBeforeMasking() {
        var calls=0
        val w=BoundedLanFrameWriter.testing {calls++}
        for(n in listOf(0,31,33,256))assertTrue(runCatching{w.invitation(ByteArray(n))}.isFailure)
        assertTrue(runCatching{w.text(ByteArray(0))}.isFailure)
        assertTrue(runCatching{w.text(ByteArray(257))}.isFailure)
        assertTrue(runCatching{w.text(byteArrayOf(-1))}.isFailure)
        assertEquals(0,calls)
    }
    @Test fun eachFrameGetsIndependentMask() {
        var calls=0
        val w=BoundedLanFrameWriter.testing {it.fill((++calls).toByte())}
        val a=w.text(byteArrayOf(65))
        val b=w.text(byteArrayOf(65))
        assertEquals(2,calls)
        assertFalse(a.contentEquals(b))
    }
}
