package com.tihulu.mobile.air

import java.io.FilterInputStream
import java.io.InputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/** Review-only main-thread gate. A cancelled worker still occupies the one slot
 * until its actual completion is delivered. Never use this as a transport permit. */
internal class AirImportLifecycle {
    enum class Kind { QR, ROOT, MODEL, TRUST }
    enum class Completion { ACCEPT, DISCARD, STALE }
    class Token internal constructor(val kind: Kind) {
        private val workerCancelled = AtomicBoolean(false)
        internal fun signalCancellation() { workerCancelled.set(true) }
        fun checkActive() {
            if (workerCancelled.get()) throw CancellationException("Import cancelled")
        }
        /** Cooperatively stop before/after each read; cannot interrupt a blocked provider. */
        fun checkedInput(input: InputStream): InputStream = object : FilterInputStream(input) {
            override fun read(): Int {
                checkActive()
                val value = super.read()
                checkActive()
                return value
            }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                checkActive()
                val count = super.read(b, off, len)
                checkActive()
                return count
            }
        }
    }
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
        active?.signalCancellation()
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
        active?.signalCancellation()
    }
}
