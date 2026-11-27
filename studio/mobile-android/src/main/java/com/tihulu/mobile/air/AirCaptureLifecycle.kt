package com.tihulu.mobile.air

/** UI-side capture admission. Does not replace transport or source deadlines.
 * Check before worker startup and before draining observations. */
internal object AirCaptureLifecycle {
    enum class Failure(val message: String) {
        INACTIVE("App inactive · stopped"),
        PERMISSION("Camera permission lost"),
        ROTATION("Display rotation changed · restart required"),
        CONTEXT("Capture generation missing · restart required")
    }

    fun failure(expectedRotation: Int?, currentRotation: Int, resumed: Boolean, permission: Boolean): Failure? {
        if (!resumed) return Failure.INACTIVE
        if (!permission) return Failure.PERMISSION
        if (expectedRotation !in listOf(0, 90, 180, 270) || currentRotation !in listOf(0, 90, 180, 270))
            return Failure.CONTEXT
        if (expectedRotation != currentRotation) return Failure.ROTATION
        return null
    }
}
