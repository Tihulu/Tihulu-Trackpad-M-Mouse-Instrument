package com.tihulu.mobile.air
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
class ArCoreCapturePolicyTest {
    @Test fun paddedInterleavedYuvAndOddDimensions() {
        fun plane(data:ByteArray,row:Int,pixel:Int)=Yuv420.Plane(ByteBuffer.wrap(data),row,pixel)
        val y=plane(byteArrayOf(16,16,16,0,16,16,16,0,16,16,16),4,1)
        val c=plane(byteArrayOf(128.toByte(),0,128.toByte(),0,128.toByte(),0,128.toByte()),4,2)
        assertArrayEquals(IntArray(9){0xff000000.toInt()},Yuv420.argb(3,3,y,c,c))
        assertNull(Yuv420.argb(4,3,y,c,c))
    }
    @Test fun inversePalmOrientation() {
        val p=PalmCoordinates.raw(.2,.3,90)!!
        assertEquals(.3,p.x,.0001);assertEquals(.8,p.y,.0001)
        val q=PalmCoordinates.raw(.2,.3,270)!!
        assertEquals(.7,q.x,.0001);assertEquals(.2,q.y,.0001)
        assertNull(PalmCoordinates.raw(.2,.3,45))
        assertNull(PalmCoordinates.raw(Double.NaN,.3,0))
    }
    @Test fun independentSensorAndConsumerClockDomains() {
        val p=AirProjection(AirMode.BEAM_HELPER,0,allowEstimatedDepth=true)
        val hands=listOf(Observation(Hand(.5,.5,.6),"right",1f))
        val t=100_000_000L
        assertNull(p.receive(Frame(hands,t,9),t,AlignedDepth(.55,DepthProvenance.ARCORE_ESTIMATED_OR_FUSED,9,9,HandRole.SINGLE)).level)
        assertEquals(.5,p.receive(Frame(hands,t+50_000_000,10),t+50_000_000,AlignedDepth(.55,DepthProvenance.ARCORE_ESTIMATED_OR_FUSED,10,10,HandRole.SINGLE)).level!!,.001)
        assertNull(p.receive(Frame(hands,t+100_000_000,11),t+100_000_000,AlignedDepth(.55,DepthProvenance.ARCORE_ESTIMATED_OR_FUSED,10,10,HandRole.SINGLE)).level)
    }
}
