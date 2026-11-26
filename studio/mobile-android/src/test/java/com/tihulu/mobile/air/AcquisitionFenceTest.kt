package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test
class AcquisitionFenceTest {
    @Test fun freshReceiptCannotResurrectOldSensorFrame() {
        val p=AirProjection(AirMode.HORIZONTAL,0)
        val hands=listOf(Observation(Hand(.4,.5,.6),"right",1f))
        assertNull(p.receive(Frame(hands,100,10),100).level)
        assertEquals(.4,p.receive(Frame(hands,50_000_100,11),50_000_100).level!!,.001)
        assertNull(p.receive(Frame(hands,100_000_100,11),100_000_100).level)
        assertNull(p.receive(Frame(hands,110_000_100,10),110_000_100).level)
        assertNull(p.receive(Frame(hands,120_000_100,12),120_000_100).level)
        assertEquals(.4,p.receive(Frame(hands,130_000_100,13),130_000_100).level!!,.001)
    }
    @Test fun staleAcquisitionCannotRearmAfterExpiry() {
        val p=AirProjection(AirMode.PINCH_KEYS,1)
        val open=listOf(Observation(Hand(.4,.5,.6),"right",1f))
        val shut=listOf(Observation(Hand(.4,.5,.1),"right",1f))
        p.receive(Frame(open,100,5),100);p.receive(Frame(open,200,6),200)
        assertEquals(1,p.receive(Frame(shut,300,7),300).keys)
        assertEquals(AirOutput(),p.expire(200_000_300))
        assertEquals(0,p.receive(Frame(open,200_000_400,7),200_000_400).keys)
        assertEquals(0,p.receive(Frame(shut,200_000_500,8),200_000_500).keys)
        assertEquals(0,p.receive(Frame(shut,200_000_600,9),200_000_600).keys)
    }
}
