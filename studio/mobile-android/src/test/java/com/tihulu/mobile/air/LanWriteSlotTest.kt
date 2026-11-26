package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class LanWriteSlotTest {
    private fun frame()=ByteArray(8){42}
    @Test fun oneLeaseOnlyAndExactCompletion() {
        val slot=LanWriteSlot();val first=frame()
        assertTrue(slot.admit(first,0))
        assertFalse(slot.admit(frame(),1))
        val lease=checkNotNull(slot.take(2))
        assertNull(slot.take(3));assertTrue(slot.writing)
        assertTrue(slot.complete(lease,4));assertFalse(slot.busy)
        lease.erase();assertTrue(first.all{it==0.toByte()})
        assertTrue(slot.admit(frame(),5))
        assertFalse(slot.complete(lease,6))
    }
    @Test fun exactDeadlineAndBackwardClock() {
        val slot=LanWriteSlot()
        assertTrue(slot.admit(frame(),10))
        assertTrue(slot.expired(9))
        val lease=checkNotNull(slot.take(10))
        assertFalse(slot.expired(10+LanWriteSlot.WRITE_NS-1))
        assertTrue(slot.expired(10+LanWriteSlot.WRITE_NS))
        assertFalse(slot.complete(lease,10+LanWriteSlot.WRITE_NS))
        slot.retire();lease.erase()
    }
    @Test fun retirementErasesUnstartedFrame() {
        val slot=LanWriteSlot();val data=frame();slot.admit(data,0)
        slot.retire();assertTrue(data.all{it==0.toByte()})
        assertNull(slot.take(1));assertFalse(slot.admit(frame(),2))
    }
    @Test fun retirementDoesNotMutateRunningWriterBuffer() {
        val slot=LanWriteSlot();val data=frame();slot.admit(data,0)
        val lease=checkNotNull(slot.take(1))
        slot.retire()
        assertTrue(data.all{it==42.toByte()})
        assertFalse(slot.complete(lease,2))
        assertFalse(slot.admit(frame(),3))
        lease.erase();assertTrue(data.all{it==0.toByte()})
    }
    @Test fun rejectsOversizeAndExpiredUnstartedFrame() {
        val slot=LanWriteSlot()
        assertFalse(slot.admit(ByteArray(265),0))
        assertFalse(slot.admit(ByteArray(5),0))
        assertFalse(slot.admit(frame(),-1))
        val data=frame();assertTrue(slot.admit(data,0))
        assertNull(slot.take(LanWriteSlot.WRITE_NS))
        slot.retire();assertTrue(data.all{it==0.toByte()})
    }
}
