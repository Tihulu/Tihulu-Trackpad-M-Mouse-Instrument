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

    private fun mask(action:AirSendGate.Action,expected:Int) {
        val bytes=(action as AirSendGate.Action.Send).bytes
        assertTrue(bytes.decodeToString().contains("\"mask\":$expected"))
    }
    @Test fun ownerPulseSustainsStationaryNoteAndActualRelease() {
        val lease=MobileTouchLiveLease(3,ms(20))
        val gate=AirSendGate(AirWireLane.Keys(3),0)
        gate.begin(0);gate.acknowledge("accepted",ms(20))
        val down=checkNotNull(lease.event(began,listOf(c(0,0.0)),ms(30),true))
        mask(gate.offer(down.output,down.ownerAt,down.ownerAt),1)
        gate.acknowledge("accepted",ms(35))
        for(time in listOf(80L,130L,180L,230L,280L)){
            val pulse=checkNotNull(lease.pulse(ms(time),true))
            mask(gate.offer(pulse.output,pulse.ownerAt,pulse.ownerAt),1)
            assertEquals(AirSendGate.Action.Wait,gate.acknowledge("accepted",ms(time+5)))
        }
        val up=checkNotNull(lease.event(ended,emptyList(),ms(295),true))
        mask(gate.offer(up.output,up.ownerAt,up.ownerAt),0)
        assertEquals(AirSendGate.Action.Wait,gate.acknowledge("accepted",ms(300)))
    }
    @Test fun independentSenderReleasesAndViewCannotRearmAfterStall() {
        val lease=MobileTouchLiveLease(1,ms(20))
        val gate=AirSendGate(AirWireLane.Keys(1),0)
        gate.begin(0);gate.acknowledge("accepted",ms(20))
        val down=checkNotNull(lease.event(began,listOf(c(0,0.0)),ms(30),true))
        gate.offer(down.output,down.ownerAt,down.ownerAt)
        gate.acknowledge("accepted",ms(35))
        mask(gate.poll(ms(180)),0)
        assertNull(lease.pulse(ms(180),true))
        gate.acknowledge("accepted",ms(185))
        assertNull(lease.event(began,listOf(c(1,0.0)),ms(190),true))
    }
}
