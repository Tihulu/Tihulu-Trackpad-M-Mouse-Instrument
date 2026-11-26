package com.tihulu.mobile.air
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class RgbaPlaneTest {
    @Test fun paddedRowsAndCropPreserveColorsAndBufferPosition() {
        val b=ByteBuffer.allocate(28)
        b.position(2)
        b.put(6,0x12);b.put(7,0x34);b.put(8,0x56);b.put(9,0x78)
        b.put(18,0x23);b.put(19,0x45);b.put(20,0x67);b.put(21,0x7f)
        val result=RgbaPlane.toArgb(b,12,4,2,2,1,0,2,2)
        assertArrayEquals(intArrayOf(0x78123456,0x7f234567),result)
        assertEquals(2,b.position())
    }
    @Test fun invalidCropAndTruncatedRowRejected() {
        val b=ByteBuffer.allocate(15)
        assertNull(RgbaPlane.toArgb(b,8,4,2,2,0,0,2,2))
        assertNull(RgbaPlane.toArgb(b,8,4,2,2,-1,0,2,2))
        assertNull(RgbaPlane.toArgb(b,8,3,2,2,0,0,2,2))
    }
}
