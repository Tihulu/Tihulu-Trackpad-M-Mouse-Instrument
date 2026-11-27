package com.tihulu.mobile.air

/** Presentation of the already freshness-filtered ARCore reading only.
 * Does not authorize capture, reset clocks, or change the logical output. */
internal object AirDepthReadout {
    const val RUNNING = "ARCore raw depth · estimated/fused"
    fun describe(workerStatus: String, observedAt: Long?, output: AirOutput): String {
        if (workerStatus != RUNNING) return workerStatus
        if (observedAt == null) return "ARCore · no fresh observation · controls released"
        if (output == AirOutput()) return "ARCore · acquiring or outside range · controls released"
        return RUNNING + " · projected output"
    }
}
