package com.tihulu.mobile.air

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

class BoundedMobileLanSocketTest {
    private val token="ab".repeat(32)
    private class BlockingChannel(private val blockSetup:Boolean):LanChannel {
        val entered=CountDownLatch(1)
        val writing=CountDownLatch(1)
        val reading=CountDownLatch(1)
        val closed=CountDownLatch(1)
        val closeCount=AtomicInteger()
        override fun open():LanChannelStreams {
            entered.countDown()
            if(blockSetup){
                closed.await(5,TimeUnit.SECONDS)
                throw IOException("fixture stopped")
            }
            val input=object:InputStream() {
                override fun read():Int {
                    reading.countDown()
                    closed.await(5,TimeUnit.SECONDS)
                    return -1
                }
            }
            val output=object:OutputStream() {
                override fun write(value:Int){throw IOException("unexpected single-byte write")}
                override fun write(bytes:ByteArray,off:Int,len:Int) {
                    writing.countDown()
                    closed.await(5,TimeUnit.SECONDS)
                    throw IOException("fixture stopped")
                }
            }
            return LanChannelStreams(input,output)
        }
        override fun close(){closeCount.incrementAndGet();closed.countDown()}
    }
    private fun await(latch:CountDownLatch)=assertTrue(latch.await(3,TimeUnit.SECONDS))
    @Test fun watchdogClosesBlockedHandshakeWithoutNetworkCallback() {
        val channel=BlockingChannel(true);val time=AtomicLong(0)
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,time::get)
        try {
            assertTrue(socket.connect(token));await(channel.entered)
            time.set(BoundedLanDriver.SETUP_NS)
            await(channel.closed)
            assertEquals(MobileLanSession.Phase.CLOSED,socket.status().phase)
            assertEquals("TLS setup timed out",socket.status().message)
            assertEquals(1,channel.closeCount.get())
            assertFalse(socket.connect(token))
        }finally{socket.stop()}
    }
    @Test fun independentWatchdogInterruptsBlockedWriteAndRead() {
        val channel=BlockingChannel(false);val time=AtomicLong(0)
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,time::get)
        try {
            assertTrue(socket.connect(token));await(channel.writing);await(channel.reading)
            time.set(LanWriteSlot.WRITE_NS)
            await(channel.closed)
            assertEquals(MobileLanSession.Phase.CLOSED,socket.status().phase)
            assertEquals("Transport write timed out",socket.status().message)
            assertNull(socket.status().assignment)
            assertEquals(1,channel.closeCount.get())
        }finally{socket.stop()}
    }
    @Test fun stopBeforeConnectNeverOpensChannel() {
        val channel=BlockingChannel(true)
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,{0})
        socket.stop();socket.stop()
        assertFalse(socket.connect(token))
        assertEquals(1L,channel.entered.count)
        assertEquals(1,channel.closeCount.get())
    }
    @Test fun explicitStopDoesNotWaitForBlockedWorkers() {
        val channel=BlockingChannel(false)
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,{0})
        try {
            assertTrue(socket.connect(token));await(channel.writing);await(channel.reading)
            socket.stop();await(channel.closed)
            assertEquals("Stopped explicitly",socket.status().message)
            assertNull(socket.newProjection(AirMode.PINCH_KEYS))
        }finally{socket.stop()}
    }

    /** Bounded, in-memory peer exercising actual read/write workers,
     * frame parsing and masking. No TLS claim or real network connection. */
    private class ScriptedChannel:LanChannel {
        private val inbound=ArrayBlockingQueue<Int>(1024)
        private val outbound=ArrayBlockingQueue<ByteArray>(8)
        val closed=CountDownLatch(1)
        override fun open():LanChannelStreams {
            val input=object:InputStream() {
                override fun read():Int = inbound.poll(5,TimeUnit.SECONDS)?:throw IOException("fixture read timed out")
            }
            val output=object:OutputStream() {
                override fun write(value:Int){throw IOException("unexpected single-byte write")}
                override fun write(bytes:ByteArray,off:Int,len:Int) {
                    if(!outbound.offer(bytes.copyOfRange(off,off+len)))throw IOException("fixture queue full")
                }
            }
            return LanChannelStreams(input,output)
        }
        fun feed(bytes:ByteArray){for(b in bytes)check(inbound.offer(b.toInt() and 255))}
        fun text(value:String) {
            val bytes=value.toByteArray(Charsets.US_ASCII)
            val header=if(bytes.size<=125)byteArrayOf(129.toByte(),bytes.size.toByte())
                else byteArrayOf(129.toByte(),126,(bytes.size shr 8).toByte(),bytes.size.toByte())
            feed(header+bytes)
        }
        fun packet():Pair<Int,ByteArray> {
            val frame=checkNotNull(outbound.poll(3,TimeUnit.SECONDS))
            check(frame[1].toInt() and 128 != 0)
            val header=if(frame[1].toInt() and 127==126)4 else 2
            val decoded=ByteArray(frame.size-header-4){i->
                (frame[header+4+i].toInt() xor frame[header+i%4].toInt()).toByte()
            }
            return (frame[0].toInt() and 15) to decoded
        }
        override fun close(){inbound.clear();inbound.offer(-1);closed.countDown()}
    }
    private fun awaitReady(socket:BoundedMobileLanSocket) {
        val end=System.nanoTime()+3_000_000_000L
        while(socket.status().phase!=MobileLanSession.Phase.READY&&System.nanoTime()<end) {
            if(socket.status().phase==MobileLanSession.Phase.CLOSED)break
            Thread.sleep(2)
        }
        assertEquals(MobileLanSession.Phase.READY,socket.status().phase)
    }
    @Test fun workersCarryMaskedAdmissionAssignedAttackAndRelease() {
        val channel=ScriptedChannel();val time=AtomicLong(0)
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,time::get)
        fun at(ms:Long){time.set(ms*1_000_000L)}
        try {
            assertTrue(socket.connect(token))
            val invite=channel.packet()
            assertEquals(2,invite.first)
            assertArrayEquals(ByteArray(32){0xab.toByte()},invite.second)
            at(1);channel.text("admitted")
            val caps=channel.packet()
            assertEquals(1,caps.first)
            assertTrue(caps.second.decodeToString().contains("capabilities"))
            at(15);channel.text("""{"kind":"capabilities","version":7,"touch":false,"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":0,"piano":1,"pedals":0}""")
            assertTrue(channel.packet().second.decodeToString().contains("\"mask\":0"))
            assertNull(socket.status().assignment)
            at(16);channel.text("accepted");awaitReady(socket)
            assertEquals(1,socket.status().assignment?.piano)
            assertNotNull(socket.newProjection(AirMode.PINCH_KEYS))
            at(30);socket.offer(AirOutput(keys=1),time.get())
            assertTrue(channel.packet().second.decodeToString().contains("\"mask\":1"))
            at(31);channel.text("accepted")
            at(32);socket.offer(AirOutput(),time.get())
            at(45);assertTrue(channel.packet().second.decodeToString().contains("\"mask\":0"))
            at(46);channel.text("accepted")
        }finally{socket.stop();await(channel.closed)}
    }
    @Test fun oversizedPeerHeaderRetiresActualReaderWithoutBody() {
        val channel=ScriptedChannel()
        val socket=BoundedMobileLanSocket(channel,MobileLanSession.Selection.Keys,{0})
        try {
            assertTrue(socket.connect(token));channel.packet()
            // Declares 257 bytes. No payload is supplied, so any read of
            // the payload would block rather than produce this close.
            channel.feed(byteArrayOf(129.toByte(),126,1,1))
            await(channel.closed)
            assertEquals(MobileLanSession.Phase.CLOSED,socket.status().phase)
            assertNull(socket.status().assignment)
        }finally{socket.stop()}
    }
}
