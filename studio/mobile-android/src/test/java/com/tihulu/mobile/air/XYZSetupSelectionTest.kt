package com.tihulu.mobile.air

import org.junit.Assert.*
import org.junit.Test

class XYZSetupSelectionTest {
    @Test fun allRolesHaveExplicitMasksAndPitchAxes() {
        for (role in 0..6) for (mask in 0..7) {
            val selection = XYZSetupSelection.from(role, mask)
            if (role in 1..3) {
                assertEquals(7, selection?.mask)
                assertEquals(role - 1, selection?.pitchAxis)
                assertFalse(checkNotNull(selection).hybrid)
            } else if (mask == 0) {
                assertNull(selection)
            } else {
                assertEquals(mask, selection?.mask)
                assertEquals(role >= 4, selection?.hybrid)
                assertEquals(if (role == 0) null else role - 4, selection?.pitchAxis)
            }
        }
    }

    @Test fun invalidOrAbsentRoleAndUnknownMaskFailClosed() {
        for (role in listOf(-1, 7, Int.MIN_VALUE, Int.MAX_VALUE))
            assertNull(XYZSetupSelection.from(role, 7))
        for (mask in listOf(-1, 8, Int.MIN_VALUE, Int.MAX_VALUE))
            assertNull(XYZSetupSelection.from(0, mask))
    }

    private val legacy: List<Any?> = listOf(0.0, 1.0, 0.0, 1.0, .25, .85, 5)

    @Test fun legacyHelperAndCanonicalInstrumentProfilesRoundTrip() {
        assertEquals(5, XYZProfileFields.decode(legacy)?.selection?.mask)
        assertEquals(0, XYZProfileFields.decode(legacy)?.selection?.roleIndex)
        val instrument = legacy.take(6) + listOf(7, 2)
        assertEquals(1, XYZProfileFields.decode(instrument)?.selection?.pitchAxis)
        assertEquals(7, XYZProfileFields.decode(instrument)?.selection?.mask)
        assertEquals(true, XYZProfileFields.decode(legacy + 6)?.selection?.hybrid)
    }

    @Test fun corruptNumericTypesOrInconsistentRoleDoNotLoad() {
        for (index in legacy.indices) {
            for (bad in listOf(null, "0.5", true, Double.NaN, Double.POSITIVE_INFINITY)) {
                assertNull(XYZProfileFields.decode(legacy.toMutableList().apply { this[index] = bad }))
            }
        }
        for (bad in listOf(-1, 7, 1.5, "2", false, null))
            assertNull(XYZProfileFields.decode(legacy + bad))
        assertNull(XYZProfileFields.decode(legacy + 1))
        assertNull(XYZProfileFields.decode(legacy.take(6) + listOf(0, 4)))
        assertNull(XYZProfileFields.decode(legacy.take(6)))
        assertNull(XYZProfileFields.decode(legacy + listOf(0, 0)))
    }
}
