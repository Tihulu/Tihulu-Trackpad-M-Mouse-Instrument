package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirDepthBoundaryTest {
    @Test fun nominalBoundaryRetainsCurrentProjectionPredicate() {
        for (near in 10..150) {
            val far = near + 10
            val n = near / 100.0
            val f = far / 100.0
            val expected = if (f - n >= .1) n to f else null
            assertEquals(expected, AirDepthCalibration.selected(3, near.toString(), far.toString()))
        }
        // 25cm -> 35cm is nominally 10cm, but current Double subtraction is below .1.
        assertNull(AirDepthCalibration.selected(3, "25", "35"))
        assertEquals(.25 to .36, AirDepthCalibration.selected(3, "25", "36"))
    }

    @Test fun everyInBoundsNineCentimetreGapRemainsRejected() {
        for (near in 11..150) {
            assertNull(AirDepthCalibration.selected(3, near.toString(), (near + 9).toString()))
        }
    }
}
