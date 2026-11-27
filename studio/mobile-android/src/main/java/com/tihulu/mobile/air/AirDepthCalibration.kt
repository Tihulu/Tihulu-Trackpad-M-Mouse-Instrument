package com.tihulu.mobile.air

/** User calibration in centimetres, not a sensor capability or confidence claim.
 * Match AirProjection's existing finite range and separation checks. */
internal object AirDepthCalibration {
    val presets = listOf(.25 to .85, .15 to .55, .4 to 1.2)

    fun selected(index: Int, nearCm: String, farCm: String): Pair<Double, Double>? {
        if (index in presets.indices) return presets[index]
        if (index != presets.size) return null
        val near = nearCm.toIntOrNull()?.takeIf { it in 10..150 } ?: return null
        val far = farCm.toIntOrNull()?.takeIf { it in 20..300 } ?: return null
        val n = near / 100.0
        val f = far / 100.0
        // Do not admit a range the current projection would reject.
        return if (f - n >= .1) n to f else null
    }
}
