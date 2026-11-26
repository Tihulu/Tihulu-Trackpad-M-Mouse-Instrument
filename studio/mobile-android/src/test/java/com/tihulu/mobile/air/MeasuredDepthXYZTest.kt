package com.tihulu.mobile.air

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class MeasuredDepthXYZTest {
    private fun plane(raw:(Int,Int)->Int):DepthPlane {
        val bytes=ByteBuffer.allocate(40*32*2).order(ByteOrder.LITTLE_ENDIAN)
        for(y in 0 until 32)for(x in 0 until 40)bytes.putShort(raw(x,y).toShort())
        bytes.flip()
        return DepthPlane(bytes,40,32,80,2,2)
    }
    @Test fun finiteTargetUsesItsOwnDepthAndRotatesInScreenSpace() {
        val surface=plane {x,y->if(x in 8..14 && y in 3..9)480 else 0}
        val p=checkNotNull(MeasuredDepthXYZ.read(surface,XYZVolume(),0))
        val rotated=checkNotNull(MeasuredDepthXYZ.read(surface,XYZVolume(),90))
        assertEquals(.48,p.metres,1e-12); assertEquals(1.0,p.confidence,0.0)
        assertEquals(p.y,rotated.x,1e-12);assertEquals(1-p.x,rotated.y,1e-12)
    }
    @Test fun refusesBackgroundAmbiguousOrLowConfidenceReturns() {
        for(surface in listOf(plane {_,_->500},
            plane {x,y->if((x in 4..10 || x in 26..33) && y in 8..15)500 else 0},
            plane {x,y->if(x in 8..14 && y in 3..9)(1 shl 13) or 500 else 0})){
            assertNull(MeasuredDepthXYZ.read(surface,XYZVolume(),0))
        }
    }
    @Test fun requiresFreshReacquisitionAndClearsAllAxesOnLoss() {
        val t=MeasuredXYZTracking(XYZVolume(),5);val p=MeasuredXYZ(.4,.5,.55,1.0)
        assertEquals(AirOutput(),t.observe(p,1,1))
        assertEquals(3,t.observe(p,2,2).xyz?.size)
        assertEquals(AirOutput(),t.observe(null,3,3))
        assertEquals(AirOutput(),t.observe(p,3,4))
        assertEquals(AirOutput(),t.observe(p,5,5))
        assertNotNull(t.observe(p,6,6).xyz)
        assertEquals(AirOutput(),t.observe(p,7,7+AirSendGate.FRESH_NS))
    }
}
