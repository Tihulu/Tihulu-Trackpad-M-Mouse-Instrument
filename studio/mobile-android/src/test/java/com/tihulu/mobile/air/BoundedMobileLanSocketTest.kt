package com.tihulu.mobile.air

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
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
}
