package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class MobileTouchLiveLeaseTest {
    private fun ms(n:Long)=n*1_000_000
    private fun c(id:Int,x:Double)=MobileTouchKeys.Contact(id,x)
    private val began=MobileTouchOwnership.Change.BEGAN
    private val ended=MobileTouchOwnership.Change.ENDED
    @Test fun stationaryOwnerPulseAndActualRelease() {
        val l=MobileTouchLiveLease(3,0)
        assertEquals(1,l.event(began,listOf(c(0,0.0)),ms(1),true)?.output?.keys)
        for(i in listOf(50L,100L,150L,200L,250L)){
            val p=l.pulse(ms(i),true)
            assertEquals(1,p?.output?.keys);assertEquals(ms(i),p?.ownerAt)
        }
        assertEquals(0,l.event(ended,emptyList(),ms(251),true)?.output?.keys)
        assertEquals(0,l.pulse(ms(300),true)?.output?.keys)
    }
    @Test fun missedPulseNeverRearmsOldTouch() {
        val l=MobileTouchLiveLease(1,0)
        l.event(began,listOf(c(0,0.0)),ms(1),true)
        assertEquals(1,l.pulse(ms(150),true)?.output?.keys)
        assertNull(l.pulse(ms(300),true))
        assertTrue(l.retired);assertEquals(0,l.output.keys)
        assertNull(l.event(began,listOf(c(1,0.0)),ms(301),true))
    }
    @Test fun focusCancelAndRollbackAreTerminal() {
        for(at in listOf(1L,0L)){
            val l=MobileTouchLiveLease(1,0)
            l.event(began,listOf(c(0,0.0)),1,true)
            assertNull(l.pulse(at,true));assertTrue(l.retired)
        }
        val l=MobileTouchLiveLease(1,0)
        l.event(began,listOf(c(0,0.0)),1,true)
        assertNull(l.pulse(2,false));assertNull(l.pulse(3,true))
        val cancel=MobileTouchLiveLease(1,0)
        cancel.event(began,listOf(c(0,0.0)),1,true)
        assertNull(cancel.event(MobileTouchOwnership.Change.CANCELLED,emptyList(),2,true))
        assertTrue(cancel.retired);assertEquals(0,cancel.output.keys)
    }
    @Test fun neutralGapAndExactPointerValidation() {
        val l=MobileTouchLiveLease(1,0)
        assertNull(l.pulse(ms(150),true));assertTrue(l.retired)
        val pointer=MobileTouchLiveLease(3,0)
        assertEquals(1,pointer.pointerEvent(began,listOf(c(2,0.0)),2,1,true)?.output?.keys)
        assertNull(pointer.pointerEvent(ended,listOf(c(3,1.0)),3,2,true))
        assertTrue(pointer.retired);assertEquals(0,pointer.output.keys)
        assertTrue(runCatching{MobileTouchLiveLease(0,0)}.isFailure)
        assertTrue(runCatching{MobileTouchLiveLease(1,-1)}.isFailure)
    }
}
