package com.tihulu.mobile.air

/** Read-only view of projected logical output. Never estimates a hand position,
 * sensor distance, tracking confidence or remote MIDI acknowledgement. */
internal data class AirStageFeedback(val slots: List<Int>, val active: Set<Int>, val level: Double?) {
    companion object {
        fun from(mode: AirMode, authorized: Int, output: AirOutput): AirStageFeedback {
            if (authorized !in 0 until (1 shl 25)) return AirStageFeedback(emptyList(), emptySet(), null)
            val keys = (0..24).filter { authorized and (1 shl it) != 0 }
            val slots = when (mode) {
                AirMode.STRINGS -> if (keys.size >= 3) keys.take(3) else emptyList()
                AirMode.BEAM_KEYS -> keys.take(8)
                else -> if (mode.isHelper) emptyList() else keys
            }
            val mask = slots.fold(0) { bits, key -> bits or (1 shl key) }
            val active = if (output.keys and mask == output.keys && output.level == null && output.xyz == null)
                slots.filter { output.keys and (1 shl it) != 0 }.toSet() else emptySet()
            val level = output.level?.takeIf { mode.isHelper && output.keys == 0 && output.xyz == null &&
                it.isFinite() && it in 0.0..1.0 }
            return AirStageFeedback(slots, active, level)
        }
    }
}
