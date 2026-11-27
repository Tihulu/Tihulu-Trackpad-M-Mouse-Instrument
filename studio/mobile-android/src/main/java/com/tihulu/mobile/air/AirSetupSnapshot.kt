package com.tihulu.mobile.air

// Proposed client-only selection snapshot. No transport or sensor activation.
internal data class AirSetupSnapshot(val mode: AirMode, val role: HandRole,
    val orientation: Orientation, val rawRotation: Int?, val near: Double, val far: Double) {
    companion object {
        fun resolve(depth: Boolean, mode: AirMode?, role: HandRole?, orientation: Int,
                    rawRotation: Int, depthRange: Pair<Double,Double>?): AirSetupSnapshot? {
            if (mode == null || role == null || (mode == AirMode.CHORDS && role == HandRole.SINGLE)) return null
            if (depth != (mode == AirMode.BEAM_KEYS || mode == AirMode.BEAM_HELPER)) return null
            val control = Orientation.entries.getOrNull(orientation) ?: return null
            val rotation = if (depth) {
                if (rawRotation !in 0..3) return null
                rawRotation * 90
            } else null
            val (near,far) = if (depth) depthRange ?: return null else AirDepthCalibration.presets.first()
            if (!near.isFinite() || !far.isFinite() || near < .1 || far > 3 || far-near < .1) return null
            return AirSetupSnapshot(mode,role,control,rotation,near,far)
        }
    }
    // Only for new pairing. Existing negotiated lane remains authoritative.
    fun canPair(helperIndex: Int): Boolean = !mode.isHelper || helperIndex in 0..2
}
