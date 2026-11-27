package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirCaptureLifecycleTest {
    @Test fun allKnownOrientationsPermitOnlyMatchingForegroundCapture() {
        for (expected in listOf(0, 90, 180, 270)) {
            for (current in listOf(0, 90, 180, 270)) {
                val result = AirCaptureLifecycle.failure(expected, current, true, true)
                if (current == expected) assertNull(result)
                else assertEquals(AirCaptureLifecycle.Failure.ROTATION, result)
            }
        }
    }

    @Test fun permissionLossDuringStartupOrCapturePreventsDelivery() {
        assertNull(AirCaptureLifecycle.failure(90, 90, true, true))
        assertEquals(AirCaptureLifecycle.Failure.PERMISSION,
            AirCaptureLifecycle.failure(90, 90, true, false))
    }

    @Test fun backgroundWinsEvenWhenPermissionAndOrientationRemainValid() {
        assertEquals(AirCaptureLifecycle.Failure.INACTIVE,
            AirCaptureLifecycle.failure(90, 90, false, true))
        assertEquals(AirCaptureLifecycle.Failure.INACTIVE,
            AirCaptureLifecycle.failure(90, 180, false, false))
    }

    @Test fun clearedOrUnknownCaptureContextCannotBeReused() {
        for (expected in listOf(null, -1, 45, 360)) {
            assertEquals(AirCaptureLifecycle.Failure.CONTEXT,
                AirCaptureLifecycle.failure(expected, 0, true, true))
        }
        assertEquals(AirCaptureLifecycle.Failure.CONTEXT,
            AirCaptureLifecycle.failure(0, -1, true, true))
    }
}
