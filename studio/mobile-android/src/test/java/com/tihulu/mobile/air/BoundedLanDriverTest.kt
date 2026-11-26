package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class BoundedLanDriverTest {
    private fun ms(n:Long)=n*1_000_000L
    private val token="ab".repeat(32)
    private val manifest="""{"kind":"capabilities","version":7,"touch":false,"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":0,"piano":1,"pedals":0}"""
    private fun driver()=BoundedLanDriver(MobileLanSession.Selection.Keys,BoundedLanFrameWriter.testing {it.fill(0x12)})
    private fun text(d:BoundedLanDriver,value:String,t:Long)=d.receive(BoundedLanFrameReader.Event.Text(value),ms(t))
    private fun write(d:BoundedLanDriver,t:Long):Pair<Int,String> {
        val lease=checkNotNull(d.take(ms(t)))
        val frame=lease.bytes
        val opcode=frame[0].toInt() and 15
        val header=if((frame[1].toInt() and 127)==126)4 else 2
        val decoded=ByteArray(frame.size-header-4){i->(frame[header+4+i].toInt() xor frame[header+i%4].toInt()).toByte()}
        d.complete(lease,ms(t));lease.erase()
        return opcode to decoded.toString(Charsets.US_ASCII)
    }
    private fun ready(d:BoundedLanDriver) {
        assertTrue(d.connect(token,0));d.verifiedUpgrade(0)
        assertEquals(2,write(d,1).first)
        text(d,"admitted",2)
        assertTrue(write(d,3).second.contains("capabilities"))
        text(d,manifest,4)
        assertNull(d.assignment)
        d.poll(ms(15))
        assertTrue(write(d,16).second.contains("\"mask\":0"))
        text(d,"accepted",17)
        assertEquals(MobileLanSession.Phase.READY,d.phase)
        assertEquals(1,d.assignment?.piano)
    }
    @Test fun fullHandshakeAndAssignedNotesOnly() {
        val d=driver();ready(d)
        d.offer(AirOutput(keys=1),ms(18),ms(30))
        assertTrue(write(d,31).second.contains("\"mask\":1"))
        text(d,"accepted",32)
        d.offer(AirOutput(keys=2),ms(33),ms(33))
        assertTrue(d.closed);assertNull(d.assignment)
    }
    @Test fun setupTimeoutWithoutAnyNetworkCallback() {
        val d=driver();d.connect(token,0)
        d.poll(ms(4999));assertFalse(d.closed)
        d.poll(ms(5000));assertTrue(d.closed)
        d.verifiedUpgrade(ms(5001));assertFalse(d.writeWaiting)
    }
    @Test fun queuedInvitationExpiresWithoutWriter() {
        val d=driver();d.connect(token,0);d.verifiedUpgrade(0)
        d.poll(ms(50));assertTrue(d.closed);assertNull(d.take(ms(51)))
    }
    @Test fun earlyReplyCannotExtendBlockedWriteDeadline() {
        val d=driver();d.connect(token,0);d.verifiedUpgrade(0)
        val lease=checkNotNull(d.take(ms(1)))
        text(d,"admitted",2)
        assertEquals(MobileLanSession.Phase.ADMISSION,d.phase)
        d.poll(ms(50));assertTrue(d.closed)
        d.complete(lease,ms(51));lease.erase()
        assertEquals(MobileLanSession.Phase.CLOSED,d.phase)
    }
    @Test fun boundedEarlyReplyProcessedOnlyAfterExactCompletion() {
        val d=driver();d.connect(token,0);d.verifiedUpgrade(0)
        val lease=checkNotNull(d.take(ms(1)))
        text(d,"admitted",2)
        assertEquals(MobileLanSession.Phase.ADMISSION,d.phase)
        d.complete(lease,ms(3));lease.erase()
        assertEquals(MobileLanSession.Phase.CAPABILITIES,d.phase)
        assertTrue(write(d,4).second.contains("capabilities"))
    }
    @Test fun unexpectedUnstartedOrSecondResponseCloses() {
        val a=driver();a.connect(token,0);a.verifiedUpgrade(0)
        text(a,"admitted",1);assertTrue(a.closed)
        val b=driver();b.connect(token,0);b.verifiedUpgrade(0)
        val lease=checkNotNull(b.take(ms(1)))
        text(b,"admitted",2);text(b,"admitted",3)
        assertTrue(b.closed);lease.erase()
    }
    @Test fun activeSensorTimeoutIndependentOfCameraAndRead() {
        val d=driver();ready(d)
        d.offer(AirOutput(keys=1),ms(30),ms(30));write(d,31);text(d,"accepted",32)
        d.poll(ms(180))
        assertTrue(write(d,181).second.contains("\"mask\":0"))
    }
    @Test fun pingCannotQueueBehindBlockedWrite() {
        val d=driver();d.connect(token,0);d.verifiedUpgrade(0)
        d.receive(BoundedLanFrameReader.Event.Ping(byteArrayOf(1)),ms(1))
        assertTrue(d.closed)
    }
}
