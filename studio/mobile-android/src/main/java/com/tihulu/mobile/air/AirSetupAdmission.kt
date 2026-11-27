package com.tihulu.mobile.air

/** Pure setup snapshot. Existing sessions retain their negotiated lane; only a new pairing reads the helper picker. */
internal data class AirSetupAdmission private constructor(
    val mode: AirMode, val role: HandRole, val orientation: Orientation,
    val depth: Boolean, val paired: Boolean, val range: Pair<Double, Double>,
    val rawRotationDegrees: Int?, val newHelperIndex: Int?
) {
    companion object {
        fun resolve(mode: AirMode?, role: HandRole?, orientation: Orientation?,
                    depth: Boolean, depthRange: Pair<Double, Double>?, rawRotationIndex: Int,
                    paired: Boolean, newPairing: Boolean, helperIndex: Int): AirSetupAdmission? {
            if (mode == null || role == null || orientation == null || (newPairing && !paired)) return null
            if (mode == AirMode.CHORDS && role == HandRole.SINGLE) return null
            if (depth != (mode == AirMode.BEAM_KEYS || mode == AirMode.BEAM_HELPER)) return null
            val range = if (depth) depthRange ?: return null else AirDepthCalibration.presets.first()
            val (near, far) = range
            if (!near.isFinite() || !far.isFinite() || near < .1 || far > 3 || far - near < .1) return null
            val raw = if (depth) {
                if (rawRotationIndex !in 0..3) return null
                rawRotationIndex * 90
            } else null
            val helper = if (newPairing && mode.isHelper) {
                if (helperIndex !in 0..2) return null
                helperIndex
            } else null
            return AirSetupAdmission(mode, role, orientation, depth, paired, range, raw, helper)
        }
    }
}
