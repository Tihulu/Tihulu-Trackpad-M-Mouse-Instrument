package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test

class AirPulseDeadlineTest {
    private fun frame(x:Double,t:Long)=Frame(listOf(Observation(Hand(x,.5,.6),"right",1f)),t)
    @Test fun partialExpiryWithoutFrames() {
        val p=AirProjection(AirMode.STRINGS,7)
        p.receive(frame(.1,0),0)
        p.receive(frame(.1,50_000_000),50_000_000)
        assertEquals(1,p.receive(frame(.4,100_000_000),100_000_000).keys)
        assertEquals(3,p.receive(frame(.65,160_000_000),160_000_000).keys)
        assertEquals(2,p.expire(230_000_000)?.keys)
        assertEquals(0,p.expire(290_000_000)?.keys)
    }
    @Test fun hysteresisAndNoDelayedAttack() {
        val p=AirProjection(AirMode.STRINGS,7)
        p.receive(frame(.1,0),0);p.receive(frame(.1,50_000_000),50_000_000)
        assertEquals(0,p.receive(frame(.26,100_000_000),100_000_000).keys)
        assertEquals(1,p.receive(frame(.28,150_000_000),150_000_000).keys)
        assertEquals(0,p.expire(271_000_000)?.keys)
        assertEquals(0,p.receive(frame(.9,280_000_000),410_000_000).keys)
    }
    @Test(expected=IllegalArgumentException::class) fun incompleteChordAuthorizationRejected() {
        AirProjection(AirMode.CHORDS,1,HandRole.RIGHT)
    }
}
