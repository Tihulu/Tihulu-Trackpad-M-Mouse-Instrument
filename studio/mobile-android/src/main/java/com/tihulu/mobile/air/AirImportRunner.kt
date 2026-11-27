package com.tihulu.mobile.air

import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** Review-only adapter. Public methods and completion callbacks run on the UI
 * thread; [post] must enqueue exactly once on that thread or return false.
 * Executor must reject before accepting a task. Use graceful shutdown on close
 * so an accepted but not yet started task can release its inputs. */
internal class AirImportRunner(
    private val executor: Executor,
    private val post: (() -> Unit) -> Boolean
) {
    enum class Start { STARTED, BUSY_OR_CLOSED, REJECTED }
    private val gate = AirImportLifecycle()
    private var closed = false
    val busy get() = gate.busy
    val cancellable get() = gate.cancellable
    fun cancel() = gate.cancel()
    fun close() { closed = true; gate.close() }

    /** Caller retains inputs if BUSY_OR_CLOSED. After admission, releaseInput
     * runs exactly once on worker or submit rejection; it must not throw.
     * discard must be thread-safe and nonthrowing. completed runs only on UI
     * for the current noncancelled token; retired runs on UI for a discarded
     * current token, to refresh controls without applying stale data. */
    fun <T> start(
        kind: AirImportLifecycle.Kind,
        work: (AirImportLifecycle.Token) -> T,
        releaseInput: () -> Unit = {},
        discard: (T) -> Unit = {},
        retired: () -> Unit = {},
        completed: (Result<T>) -> Unit
    ): Start {
        val token = gate.begin(kind) ?: return Start.BUSY_OR_CLOSED
        try {
            executor.execute {
                val result = try { runCatching { token.checkActive(); work(token) } } finally { releaseInput() }
                // A false post means the UI dispatcher is unavailable. Never
                // unlock the gate off-thread or admit a new task on that owner.
                if (!post {
                    when (gate.finish(token)) {
                        AirImportLifecycle.Completion.ACCEPT -> completed(result)
                        AirImportLifecycle.Completion.DISCARD -> {
                            result.onSuccess(discard)
                            if (!closed) retired()
                        }
                        AirImportLifecycle.Completion.STALE -> result.onSuccess(discard)
                    }
                }) result.onSuccess(discard)
            }
        } catch (e: RejectedExecutionException) {
            releaseInput()
            check(gate.finish(token) == AirImportLifecycle.Completion.ACCEPT)
            completed(Result.failure(e))
            return Start.REJECTED
        }
        return Start.STARTED
    }
}
