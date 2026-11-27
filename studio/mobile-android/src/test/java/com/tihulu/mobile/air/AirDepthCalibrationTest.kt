package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirDepthCalibrationTest {
    @Test fun presetsIgnoreIncompleteCustomFields() {
        assertEquals(.25 to .85, AirDepthCalibration.selected(0, "", ""))
        assertEquals(.15 to .55, AirDepthCalibration.selected(1, "", ""))
        assertEquals(.4 to 1.2, AirDepthCalibration.selected(2, "", ""))
    }
    @Test fun customRangeMatchesProjectionBounds() {
        for ((near, far) in listOf(10 to 20, 28 to 93, 150 to 300)) {
            val range = checkNotNull(AirDepthCalibration.selected(3, near.toString(), far.toString()))
            assertEquals(near / 100.0, range.first, 0.0)
            assertEquals(far / 100.0, range.second, 0.0)
            AirProjection(AirMode.BEAM_KEYS, 1, near = range.first, far = range.second)
            AirProjection(AirMode.BEAM_HELPER, 0, near = range.first, far = range.second)
        }
    }
    @Test fun malformedReversedAndTooCloseRangesNeverFallBack() {
        for ((near, far) in listOf("" to "85", "25" to "", "NaN" to "85", "25.5" to "85",
            "9" to "85", "151" to "300", "25" to "301", "50" to "49", "50" to "59", "99" to "99")) {
            assertNull(AirDepthCalibration.selected(3, near, far))
        }
        assertNull(AirDepthCalibration.selected(-1, "25", "85"))
        assertNull(AirDepthCalibration.selected(4, "25", "85"))
    }
    @Test fun customRangeDoesNotAuthorizeEstimatedDepthOrStaleFrames() {
        val (near, far) = checkNotNull(AirDepthCalibration.selected(3, "28", "93"))
        val p = AirProjection(AirMode.BEAM_HELPER, 0, near = near, far = far)
        val hands = listOf(Observation(Hand(.5, .5, .6), "right", 1f))
        fun step(at: Long, now: Long, provenance: DepthProvenance, metres: Double): AirOutput =
            p.receive(Frame(hands, at), now, AlignedDepth(metres, provenance, at, at, HandRole.SINGLE))
        val estimated = DepthProvenance.ARCORE_ESTIMATED_OR_FUSED
        val measured = DepthProvenance.CAMERA2_DEPTH16
        assertEquals(AirOutput(), step(1, 1, estimated, .5))
        assertEquals(AirOutput(), step(2, 2, measured, .5))
        assertNotNull(step(3, 3, measured, .5).level)
        assertEquals(AirOutput(), step(4, 150_000_004, measured, .5))
        assertEquals(AirOutput(), step(150_000_005, 150_000_005, measured, .1))
    }
}
