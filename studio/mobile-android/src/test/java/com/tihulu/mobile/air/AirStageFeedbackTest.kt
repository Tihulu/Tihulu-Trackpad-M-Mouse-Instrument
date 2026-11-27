package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class AirStageFeedbackTest {
    private fun mask(vararg keys: Int) = keys.fold(0) { bits, key -> bits or (1 shl key) }

    @Test fun sparseAssignedKeysNeverBecomeContiguousNotes() {
        val s = AirStageFeedback.from(AirMode.PINCH_KEYS, mask(0, 8, 24), AirOutput(keys = mask(8)))
        assertEquals(listOf(0, 8, 24), s.slots)
        assertEquals(setOf(8), s.active)
        assertNull(s.level)
    }

    @Test fun stringsAndBeamOnlyShowTheirActualProjectionSlots() {
        val all = (1 shl 25) - 1
        assertEquals(listOf(0, 1, 2), AirStageFeedback.from(AirMode.STRINGS, all, AirOutput()).slots)
        assertEquals((0..7).toList(), AirStageFeedback.from(AirMode.BEAM_KEYS, all, AirOutput()).slots)
        assertTrue(AirStageFeedback.from(AirMode.STRINGS, mask(0, 2), AirOutput(keys = 1)).slots.isEmpty())
        assertTrue(AirStageFeedback.from(AirMode.BEAM_KEYS, all, AirOutput(keys = mask(8))).active.isEmpty())
    }

    @Test fun chordAndStringReleaseOnlyClearsReleasedKeys() {
        val all = (1 shl 25) - 1
        assertEquals(setOf(0, 4, 7), AirStageFeedback.from(AirMode.CHORDS, all, AirOutput(keys = mask(0, 4, 7))).active)
        assertEquals(setOf(1), AirStageFeedback.from(AirMode.STRINGS, all, AirOutput(keys = mask(1))).active)
        assertTrue(AirStageFeedback.from(AirMode.STRINGS, all, AirOutput()).active.isEmpty())
    }

    @Test fun zeroHelperLevelIsDifferentFromReleasedAndMalformedLevels() {
        for (mode in AirMode.entries.filter { it.isHelper }) {
            assertEquals(0.0, AirStageFeedback.from(mode, 0, AirOutput(level = 0.0)).level)
            assertNull(AirStageFeedback.from(mode, 0, AirOutput()).level)
            for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, -0.01, 1.01))
                assertNull(AirStageFeedback.from(mode, 0, AirOutput(level = bad)).level)
        }
    }

    @Test fun foreignLaneOrUnauthorizedOutputDoesNotHighlightAnything() {
        assertTrue(AirStageFeedback.from(AirMode.PINCH_KEYS, mask(0), AirOutput(keys = mask(0, 1))).active.isEmpty())
        assertTrue(AirStageFeedback.from(AirMode.PINCH_KEYS, mask(0), AirOutput(keys = 1, level = .5)).active.isEmpty())
        assertNull(AirStageFeedback.from(AirMode.HORIZONTAL, 0, AirOutput(level = .5, xyz = listOf(.5, null, null))).level)
        assertNull(AirStageFeedback.from(AirMode.HORIZONTAL, -1, AirOutput(level = .5)).level)
        assertNull(AirStageFeedback.from(AirMode.PINCH_KEYS, 1, AirOutput(level = .5)).level)
    }
}
