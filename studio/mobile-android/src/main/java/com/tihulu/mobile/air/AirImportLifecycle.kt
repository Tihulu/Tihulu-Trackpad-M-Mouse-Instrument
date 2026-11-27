package com.tihulu.mobile.air

/** Review-only main-thread gate. A cancelled worker still occupies the one slot
 * until its actual completion is delivered. Never use this as a transport permit. */
internal class AirImportLifecycle {
    enum class Kind { QR, ROOT, MODEL, TRUST }
    enum class Completion { ACCEPT, DISCARD, STALE }
    class Token internal constructor(val kind: Kind)
    private var active: Token? = null
    private var cancelled = false
    private var closed = false
    val busy: Boolean get() = active != null
    val cancellable: Boolean get() = busy && !cancelled && !closed

    fun begin(kind: Kind): Token? {
        if (closed || active != null) return null
        return Token(kind).also { active = it; cancelled = false }
    }
    fun cancel(): Kind? {
        if (!cancellable) return null
        cancelled = true
        return active?.kind
    }
    fun finish(token: Token): Completion {
        if (active !== token) return Completion.STALE
        val result = if (closed || cancelled) Completion.DISCARD else Completion.ACCEPT
        active = null
        cancelled = false
        return result
    }
    fun close() {
        closed = true
        cancelled = true
    }
}
