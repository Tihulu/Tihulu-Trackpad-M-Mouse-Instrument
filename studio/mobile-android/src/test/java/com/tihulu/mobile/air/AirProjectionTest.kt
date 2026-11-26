package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test

class AirProjectionTest {
    private fun h(open:Boolean=true,side:String="right",fingers:Int?=null)=Observation(Hand(.25,.5,if(open).6 else .1),side,1f,fingers)
    @Test fun releaseAndRearm() {
        val p=AirProjection(AirMode.PINCH_KEYS,17)
        var t=0L
        fun step(open:Boolean):AirOutput {t+=60_000_000;return p.receive(Frame(listOf(h(open)),t),t)}
        assertEquals(0,step(false).keys);assertEquals(0,step(false).keys)
        step(true);assertEquals(1,step(false).keys)
        assertEquals(AirOutput(),p.expire(t+160_000_000))
        assertEquals(0,step(false).keys);assertEquals(0,step(false).keys)
    }
    @Test fun rotatedHelperAndLoss() {
        val p=AirProjection(AirMode.HORIZONTAL,0,HandRole.RIGHT,Orientation.DOWN)
        assertNull(p.receive(Frame(listOf(h()),1),1).level)
        assertEquals(.75,p.receive(Frame(listOf(h()),50_000_001),50_000_001).level!!,.0001)
        assertNull(p.receive(Frame(listOf(h(side="left")),100_000_001),100_000_001).level)
    }
    @Test fun estimatedDepthNeverSilentlySubstitutesForHardware() {
        val p=AirProjection(AirMode.BEAM_HELPER,0)
        var t=0L
        fun step(source:DepthProvenance,offset:Long=0):AirOutput {
            t+=60_000_000
            return p.receive(Frame(listOf(h()),t),t,AlignedDepth(.55,source,t,t+offset,HandRole.SINGLE))
        }
        assertNull(step(DepthProvenance.ARCORE_ESTIMATED_OR_FUSED).level)
        assertNull(step(DepthProvenance.CAMERA2_DEPTH16).level)
        assertEquals(.5,step(DepthProvenance.CAMERA2_DEPTH16).level!!,.0001)
        assertNull(step(DepthProvenance.CAMERA2_DEPTH16,1).level)
    }
    @Test fun chordRequiresTwoHands() {
        val p=AirProjection(AirMode.CHORDS,145,HandRole.RIGHT)
        var t=0L
        fun step(count:Int,open:Boolean=true,selector:Boolean=true):AirOutput {
            t+=60_000_000
            val hands=listOf(h(open))+(if(selector)listOf(h(side="left",fingers=count))else emptyList())
            return p.receive(Frame(hands,t),t)
        }
        step(0);step(0)
        repeat(4){step(1)}
        assertEquals(145,step(1,false).keys)
        assertEquals(0,step(1,false,false).keys)
    }
}
