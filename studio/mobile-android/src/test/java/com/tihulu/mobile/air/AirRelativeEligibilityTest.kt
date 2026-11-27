package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirRelativeEligibilityTest {
    @Test fun onlyPositionalHelpersAreCandidateSources() {
        val candidates = AirMode.entries.filter { AirRelativeEligibility.forMode(it) == AirRelativeEligibility.POSITION }.toSet()
        assertEquals(setOf(AirMode.HORIZONTAL, AirMode.VERTICAL, AirMode.APERTURE, AirMode.BEAM_HELPER), candidates)
        assertTrue(candidates.all { it.isHelper })
    }
    @Test fun allNotesAndBinaryHelpersRemainDiscrete() {
        val modes = AirMode.entries.filter { AirRelativeEligibility.forMode(it) == AirRelativeEligibility.DISCRETE }.toSet()
        assertEquals(setOf(AirMode.PINCH_KEYS, AirMode.CHORDS, AirMode.STRINGS, AirMode.BEAM_KEYS,
            AirMode.PINCH_HELPER, AirMode.TOGGLE_HELPER), modes)
    }
    @Test fun speedIsNotPositionAndNoCandidateClaimsHostAuthorization() {
        assertEquals(AirRelativeEligibility.DERIVED, AirRelativeEligibility.forMode(AirMode.SPEED))
        assertTrue(AirRelativeEligibility.POSITION.explanation.contains("not negotiated"))
        assertEquals(11, AirMode.entries.size)
    }
}
