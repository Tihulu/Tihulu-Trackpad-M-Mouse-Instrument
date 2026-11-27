package com.tihulu.mobile.air

/** UI setup selection. An absent or corrupt role must not become Helper. */
internal data class XYZSetupSelection private constructor(
    val roleIndex: Int, val mask: Int, val pitchAxis: Int?, val hybrid: Boolean
) {
    companion object {
        fun from(roleIndex: Int, checkedAxes: Int): XYZSetupSelection? {
            if (roleIndex !in 0..6 || checkedAxes !in 0..7) return null
            val pitch = if (roleIndex == 0) null else (roleIndex - 1) % 3
            val hybrid = roleIndex >= 4
            val mask = if (pitch != null && !hybrid) 7 else checkedAxes
            if (mask == 0) return null
            return XYZSetupSelection(roleIndex, mask, pitch, hybrid)
        }
    }
}

/** Saved calibration fields are JSON numbers, not coercible strings or flags. */
internal data class XYZProfileFields(val volume: XYZVolume, val selection: XYZSetupSelection) {
    companion object {
        fun decode(raw: List<Any?>): XYZProfileFields? {
            if (raw.size !in 7..8) return null
            val values = raw.map { (it as? Number)?.toDouble()?.takeIf(Double::isFinite) ?: return null }
            val volume = XYZVolume(values[0], values[1], values[2], values[3], values[4], values[5])
            if (!volume.valid) return null
            val mask = XYZCalibrationRecord.axisMask(values[6]) ?: return null
            val role = if (values.size == 8) XYZCalibrationRecord.roleIndex(values[7]) ?: return null else 0
            val selection = XYZSetupSelection.from(role, mask) ?: return null
            // Instrument-only saved profiles already use all three axes for acquisition.
            if (selection.mask != mask) return null
            return XYZProfileFields(volume, selection)
        }
    }
}
