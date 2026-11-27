package com.tihulu.mobile.air

import org.junit.Test

class AirSetupAdmissionTest {
    @Test fun setupDomainAndPairingContext() {
        val beam = setOf(AirMode.BEAM_KEYS, AirMode.BEAM_HELPER)
        val helpers = setOf(AirMode.HORIZONTAL, AirMode.VERTICAL, AirMode.APERTURE, AirMode.SPEED,
            AirMode.PINCH_HELPER, AirMode.TOGGLE_HELPER, AirMode.BEAM_HELPER)
        val ranges = listOf(null, .25 to .85, .25 to .35, .25 to .34, Double.NaN to .85,
            .05 to .85, .25 to 3.01, .25 to Double.POSITIVE_INFINITY)
        val indices = listOf(Int.MIN_VALUE, -1, 0, 1, 2, 3, 4, Int.MAX_VALUE)
        var cases = 0
        var admitted = 0
        for (mode in listOf(null) + AirMode.entries) for (role in listOf(null) + HandRole.entries)
        for (orientation in listOf(null) + Orientation.entries) for (depth in listOf(false, true))
        for ((ri, range) in ranges.withIndex()) for (raw in indices) for (paired in listOf(false, true))
        for (newPair in listOf(false, true)) for (helper in indices) {
            val expected = mode != null && role != null && orientation != null && (!newPair || paired) &&
                !(mode == AirMode.CHORDS && role == HandRole.SINGLE) && depth == (mode in beam) &&
                (!depth || (ri == 1 && raw in 0..3)) && (!newPair || mode !in helpers || helper in 0..2)
            val actual = AirSetupAdmission.resolve(mode, role, orientation, depth, range, raw, paired, newPair, helper)
            check((actual != null) == expected)
            if (actual != null) {
                admitted++
                check(actual.mode == mode && actual.role == role && actual.orientation == orientation)
                check(actual.paired == paired && actual.depth == depth)
                check(actual.range == (if (depth) range else .25 to .85))
                check(actual.rawRotationDegrees == (if (depth) raw * 90 else null))
                check(actual.newHelperIndex == (if (newPair && mode in helpers) helper else null))
            }
            cases++
        }
        println("PASS $cases combinations ($admitted admitted)")
    }

    @Test fun existingLaneAndStrictRange() {
        fun helper(index: Int, newPair: Boolean) = AirSetupAdmission.resolve(AirMode.HORIZONTAL,
            HandRole.LEFT, Orientation.UP, false, null, -1, true, newPair, index)
        val existing = helper(0, false)!!
        for (index in listOf(Int.MIN_VALUE, -1, 0, 1, 2, 3, Int.MAX_VALUE)) {
            check(helper(index, false) == existing)
            check((helper(index, true) != null) == (index in 0..2))
            check(helper(index, true)?.newHelperIndex == index.takeIf { it in 0..2 })
        }
        check(AirDepthCalibration.selected(3, "25", "35") == null)
        check(AirDepthCalibration.selected(3, "25", "36") != null)
        println("PASS 23 existing-lane and strict-range assertions")
    }
}
