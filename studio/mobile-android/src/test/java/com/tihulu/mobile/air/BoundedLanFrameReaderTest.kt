package com.tihulu.mobile.air

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class BoundedLanFrameReaderTest {
    private fun frame(first:Int,body:ByteArray):ByteArray {
        val header=if(body.size<126)byteArrayOf(first.toByte(),body.size.toByte())
            else byteArrayOf(first.toByte(),126,(body.size shr 8).toByte(),body.size.toByte())
        return header+body
    }
    private fun text(first:Int,value:String)=frame(first,value.toByteArray(Charsets.US_ASCII))
    private fun reader(bytes:ByteArray)=BoundedLanFrameReader(ByteArrayInputStream(bytes))
    private fun rejects(r:BoundedLanFrameReader) {
        assertTrue(runCatching {r.next()}.exceptionOrNull() is IOException)
        assertTrue(runCatching {r.next()}.exceptionOrNull() is IOException)
    }
    @Test fun normalTextAndExactMaximum() {
        val r=reader(text(129,"admitted")+text(129,"x".repeat(256)))
        assertEquals(BoundedLanFrameReader.Event.Text("admitted"),r.next())
        assertEquals(BoundedLanFrameReader.Event.Text("x".repeat(256)),r.next())
    }
    @Test fun fragmentedTextWithInterleavedControl() {
        val r=reader(text(1,"ac")+text(137,"probe")+text(0,"cep")+text(128,"ted"))
        val ping=r.next() as BoundedLanFrameReader.Event.Ping
        assertArrayEquals("probe".toByteArray(),ping.payload)
        assertEquals(BoundedLanFrameReader.Event.Text("accepted"),r.next())
    }
    @Test fun declaredOversizeRejectedBeforePayloadRead() {
        val stream=ByteArrayInputStream(byteArrayOf(129.toByte(),126,1,1,42,43))
        rejects(BoundedLanFrameReader(stream))
        assertEquals(2,stream.available())
        val long=ByteArrayInputStream(byteArrayOf(129.toByte(),127,42,43))
        rejects(BoundedLanFrameReader(long))
        assertEquals(2,long.available())
    }
    @Test fun aggregateLimitCheckedBeforeContinuationPayload() {
        val stream=ByteArrayInputStream(text(1,"x".repeat(256))+text(128,"z"))
        rejects(BoundedLanFrameReader(stream))
        assertEquals(1,stream.available())
    }
    @Test fun excessiveEmptyFragmentsRejected() {
        val pieces=List(15){text(0,"")}.fold(text(1,"")){a,b->a+b}
        rejects(reader(pieces+text(128,"")))
        val permitted=List(14){text(0,"")}.fold(text(1,"")){a,b->a+b}
        assertEquals(BoundedLanFrameReader.Event.Text("ok"),reader(permitted+text(128,"ok")).next())
    }
    @Test fun invalidHeadersAndContinuationOrder() {
        for(bytes in listOf(
            byteArrayOf(129.toByte(),128.toByte()), // masked server
            byteArrayOf(193.toByte(),0), // extension not negotiated
            byteArrayOf(130.toByte(),0), // binary
            byteArrayOf(129.toByte(),126,0,1), // noncanonical length
            text(128,"orphan"),text(1,"a")+text(129,"b"),
            text(9,"control cannot fragment"),byteArrayOf(137.toByte(),126),
            text(136,"x"),frame(129,byteArrayOf(0xff.toByte()))
        ))rejects(reader(bytes))
    }
    @Test fun closeAndTruncationAreTerminal() {
        val r=reader(text(136,"")+text(129,"admitted"))
        assertEquals(BoundedLanFrameReader.Event.Close,r.next())
        rejects(r)
        rejects(reader(byteArrayOf(129.toByte(),3,97)))
    }
}
