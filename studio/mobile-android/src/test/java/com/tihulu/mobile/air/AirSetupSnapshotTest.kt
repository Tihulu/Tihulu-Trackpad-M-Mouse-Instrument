package com.tihulu.mobile.air

import org.junit.Test

class AirSetupSnapshotTest {
    @Test fun setupAdmissionMatrix() {
        val modes = listOf(null,*AirMode.entries.toTypedArray())
        val roles = listOf(null,*HandRole.entries.toTypedArray())
        val indexes = listOf(Int.MIN_VALUE,-1,0,1,2,3,4,Int.MAX_VALUE)
        val ranges = listOf(null,.25 to .85,.25 to .35,.25 to .36,.5 to .4,.09 to .9,.25 to 3.01,Double.NaN to .9,.25 to Double.POSITIVE_INFINITY)
        for (depth in listOf(false,true)) for (mode in modes) for (role in roles) for (orient in indexes) for (raw in indexes) for (range in ranges) {
            val result = AirSetupSnapshot.resolve(depth,mode,role,orient,raw,range)
            val modeOK = if (depth) mode in listOf(AirMode.BEAM_KEYS,AirMode.BEAM_HELPER) else mode != null && mode !in listOf(AirMode.BEAM_KEYS,AirMode.BEAM_HELPER)
            val rangeOK = !depth || (range != null && range.first.isFinite() && range.second.isFinite() && range.first >= .1 && range.second <= 3 && range.second - range.first >= .1)
            val expected = modeOK && role != null && !(mode == AirMode.CHORDS && role == HandRole.SINGLE) && orient in 0..3 && (!depth || raw in 0..3) && rangeOK
            check((result != null) == expected)
            if (result == null) continue
            check(result.mode == mode && result.role == role && result.orientation.ordinal == orient)
            check(result.rawRotation == if (depth) raw*90 else null)
            check((result.near to result.far) == if (depth) range else (.25 to .85))
            for (helper in indexes) check(result.canPair(helper) == (!result.mode.isHelper || helper in 0..2))
        }
    }

    @Test fun existingLaneDoesNotFollowNewPairingPicker() {
        val setup = checkNotNull(AirSetupSnapshot.resolve(false,AirMode.HORIZONTAL,HandRole.SINGLE,0,-1,null))
        val indexes = listOf(Int.MIN_VALUE,-1,0,1,2,3,Int.MAX_VALUE)
        for (pedals in 0..63) for (initial in indexes) for (current in indexes) {
            val raw = """{"kind":"capabilities","version":7,"touch":false,"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":0,"piano":0,"pedals":$pedals}"""
            val lane = MobileLanCapabilities.parseSingleFamily(raw)?.helperLane(initial)
            check((lane != null) == (initial in 0..2 && (pedals and (1 shl initial)) != 0))
            check(setup.canPair(current) == (current in 0..2))
            if (lane != null) {
                check(lane.encode(AirOutput(level=.25),2).decodeToString().contains("\"mask\":${1 shl initial},"))
                check(lane.encode(AirOutput(level=.75),3).decodeToString().contains("\"mask\":${1 shl initial},"))
                check(lane.encode(AirOutput(),4).decodeToString().contains("\"mask\":0,\"levels\":[0,0,0,0,0,0]"))
            }
        }
    }
}
