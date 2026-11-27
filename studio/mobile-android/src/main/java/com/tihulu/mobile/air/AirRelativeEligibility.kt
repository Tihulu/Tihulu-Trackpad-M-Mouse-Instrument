package com.tihulu.mobile.air

/** Source eligibility only, not host permission or negotiated response mode. */
internal enum class AirRelativeEligibility(val explanation: String) {
    POSITION("Position source · Relative is a proposed host response; not negotiated on mobile."),
    DERIVED("Speed source · keep absolute until a separate relative-speed contract is reviewed."),
    DISCRETE("Discrete notes or gates · no relative displacement.");
    companion object {
        fun forMode(mode: AirMode): AirRelativeEligibility = when (mode) {
            AirMode.HORIZONTAL, AirMode.VERTICAL, AirMode.APERTURE, AirMode.BEAM_HELPER -> POSITION
            AirMode.SPEED -> DERIVED
            AirMode.PINCH_KEYS, AirMode.CHORDS, AirMode.STRINGS, AirMode.PINCH_HELPER,
            AirMode.TOGGLE_HELPER, AirMode.BEAM_KEYS -> DISCRETE
        }
    }
}
