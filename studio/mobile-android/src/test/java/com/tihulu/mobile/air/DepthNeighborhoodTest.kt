package com.tihulu.mobile.air

import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class DepthNeighborhoodTest {
    private fun depth(value:Int):ByteBuffer=ByteBuffer.allocate(24).apply {
        for(y in 0..2)for(x in 0..2) {
            val i=y*8+x*2;put(i,(value and 255).toByte());put(i+1,(value ushr 8).toByte())
        }
    }
    @Test fun camera2UsesPackedConfidenceButArcoreDoesNot() {
        val d=DepthPlane(depth(400),3,3,8,2,2)
        assertEquals(.4,DepthNeighborhood.camera2(d,1,1)!!,.0001)
        val high=ByteBuffer.allocate(12).apply {for(i in 0..11)put(i,255.toByte())}
        val c=DepthPlane(high,3,3,4,1,1)
        val wide=DepthPlane(depth(9000),3,3,8,2,2)
        assertNull(DepthNeighborhood.camera2(wide,1,1))
        assertEquals(9.0,DepthNeighborhood.arCore(wide,c,1,1)!!,.0001)
    }
    @Test fun sparseAndTruncatedDataFailClosed() {
        val d=DepthPlane(depth(400),3,3,8,2,2)
        val c=DepthPlane(ByteBuffer.allocate(12),3,3,4,1,1)
        assertNull(DepthNeighborhood.arCore(d,c,1,1))
        assertNull(DepthNeighborhood.camera2(d,0,1))
        assertNull(DepthNeighborhood.camera2(DepthPlane(ByteBuffer.allocate(12),3,3,8,2,2),1,1))
        assertNull(DepthPlane(ByteBuffer.allocate(9),3,3,1,2,2).read(1,1))
    }
    @Test fun rejectsInconsistentDepthNeighborhood() {
        val b=depth(400)
        for(i in listOf(0,2,4,8,10)) {b.put(i,0xd0.toByte());b.put(i+1,0x07.toByte())}
        val d=DepthPlane(b,3,3,8,2,2)
        assertEquals(2.0,DepthNeighborhood.camera2(d,1,1)!!,.0001)
        b.put(10,0);b.put(11,0)
        assertNull(DepthNeighborhood.camera2(d,1,1))
    }
}
