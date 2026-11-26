package com.tihulu.mobile.air
import org.junit.Assert.*
import org.junit.Test

class AirSensorPolicyTest {
    @Test fun zoomBounds() {
        val z=ZoomRange(.5f,8f)
        assertTrue(z.admits(.5f)); assertFalse(z.admits(10f));assertFalse(z.admits(Float.NaN))
        assertEquals(1f,z.reset)
    }
    @Test fun depthConfidenceAndConsensus() {
        assertEquals(0.4,DepthPolicy.decode(400)!!,0.0001)
        assertNull(DepthPolicy.decode((1 shl 13) or 400))
        assertNull(DepthPolicy.decode(0))
        assertEquals(0.4,DepthPolicy.palmDepth(List(5){400}+List(4){2000})!!,0.0001)
        assertNull(DepthPolicy.palmDepth(List(4){400}+List(4){2000}+listOf(0)))
        assertFalse(DepthPolicy.sameAcquisition(1,2))
        assertTrue(DepthPolicy.sameAcquisition(1,1))
    }
    @Test fun normalizedHand() {
        val h=Hand.from(Point(.4,.6),Point(.5,.6),Point(.5,.2),Point(.5,.4))!!
        assertEquals(.5,h.x,0.0001)
        assertNull(Hand.from(Point(.4,.6),Point(2.0,.6),Point(.5,.2),Point(.5,.4)))
    }
}
