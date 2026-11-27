package com.tihulu.mobile.air

import org.junit.Test
import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private var checks = 0
private fun expect(ok: Boolean) { checks++; check(ok) }
private class Fixture {
    val worker = ArrayDeque<Runnable>()
    val ui = ArrayDeque<() -> Unit>()
    var reject = false
    var postRejected = false
    val runner = AirImportRunner(Executor { if (reject) throw RejectedExecutionException("fixture"); worker.addLast(it) },
        { if (postRejected) false else { ui.addLast(it); true } })
    var released = 0
    var discarded = 0
    var retired = 0
    var accepted = 0
    var failures = 0
    var worked = 0
    fun start(kind: AirImportLifecycle.Kind, fail: Boolean = false): AirImportRunner.Start = runner.start(kind, work = {
        worked++; if (fail) error("fixture work failed"); 42
    }, releaseInput = { released++ }, discard = { expect(it == 42); discarded++ }, retired = { retired++ }) { result ->
        if (result.isSuccess) { expect(result.getOrThrow() == 42); accepted++ } else failures++
    }
    fun runWorker() = worker.removeFirst().run()
    fun runUI() = ui.removeFirst().invoke()
}
private fun perKind(kind: AirImportLifecycle.Kind) {
    val started = AirImportRunner.Start.STARTED
    val denied = AirImportRunner.Start.BUSY_OR_CLOSED
    // Success, pending UI, repeated refusal, next generation.
    Fixture().apply {
        expect(start(kind) == started); expect(runner.busy && runner.cancellable)
        repeat(32) { expect(start(kind) == denied) }
        expect(worker.size == 1); runWorker(); expect(released == 1 && worked == 1)
        expect(runner.busy && accepted == 0); expect(start(kind) == denied); runUI()
        expect(!runner.busy && accepted == 1 && discarded == 0 && retired == 0)
        expect(start(kind) == started); runWorker(); runUI(); expect(accepted == 2 && released == 2)
    }
    // Cancel before work or after completion is queued. Result never applied.
    for (early in listOf(true, false)) Fixture().apply {
        expect(start(kind) == started)
        if (!early) runWorker()
        expect(runner.cancel() == kind); expect(runner.cancel() == null)
        expect(runner.busy && !runner.cancellable)
        repeat(32) { expect(start(kind) == denied) }
        if (early) runWorker()
        expect(runner.busy && discarded == 0); runUI()
        expect(!runner.busy && accepted == 0 && discarded == 1 && retired == 1 && released == 1)
        expect(start(kind) == started); runWorker(); runUI(); expect(accepted == 1 && discarded == 1)
    }
    // Worker error, cancelled error, and rejected submit.
    for (cancel in listOf(false, true)) Fixture().apply {
        expect(start(kind, fail = true) == started)
        if (cancel) runner.cancel()
        runWorker(); runUI(); expect(!runner.busy && released == 1)
        expect(failures == if (cancel) 0 else 1); expect(retired == if (cancel) 1 else 0)
    }
    Fixture().apply {
        reject = true; expect(start(kind) == AirImportRunner.Start.REJECTED)
        expect(!runner.busy && released == 1 && failures == 1 && worked == 0 && worker.isEmpty())
        reject = false; expect(start(kind) == started); runWorker(); runUI(); expect(accepted == 1)
    }
    // Destroy before execution, after execution, or after cancellation.
    for (phase in 0..2) Fixture().apply {
        expect(start(kind) == started)
        if (phase == 1) runWorker()
        if (phase == 2) runner.cancel()
        runner.close(); runner.close(); expect(start(kind) == denied)
        if (phase != 1) runWorker()
        runUI(); expect(!runner.busy && !runner.cancellable && accepted == 0 && retired == 0)
        expect(discarded == 1 && released == 1 && start(kind) == denied)
    }
    Fixture().apply {
        postRejected = true; expect(start(kind) == started); runWorker()
        expect(runner.busy && released == 1 && discarded == 1 && accepted == 0 && ui.isEmpty())
        expect(start(kind) == denied); runner.close(); expect(start(kind) == denied)
    }
}
private fun realExecutor() {
    val worker = Executors.newSingleThreadExecutor()
    val mailbox = LinkedBlockingQueue<() -> Unit>()
    val runner = AirImportRunner(worker, { mailbox.offer(it) })
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val released = AtomicInteger()
    val discards = AtomicInteger()
    val uiThread = Thread.currentThread()
    var applied = 0
    var retired = 0
    try {
        expect(runner.start(AirImportLifecycle.Kind.TRUST, work = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); "result"
        }, releaseInput = { released.incrementAndGet() }, discard = { discards.incrementAndGet() }, retired = {
            expect(Thread.currentThread() === uiThread); retired++
        }) { applied++ } == AirImportRunner.Start.STARTED)
        expect(entered.await(5, TimeUnit.SECONDS)); expect(runner.cancel() == AirImportLifecycle.Kind.TRUST)
        repeat(1024) { expect(runner.start(AirImportLifecycle.Kind.MODEL, work = { error("must not start") }) {} == AirImportRunner.Start.BUSY_OR_CLOSED) }
        release.countDown(); val callback = mailbox.poll(5, TimeUnit.SECONDS); expect(callback != null)
        expect(runner.busy && released.get() == 1); callback!!()
        expect(!runner.busy && discards.get() == 1 && retired == 1 && applied == 0)
        expect(runner.start(AirImportLifecycle.Kind.MODEL, work = { 1 }) { expect(Thread.currentThread() === uiThread); expect(it.getOrThrow() == 1); applied++ } == AirImportRunner.Start.STARTED)
        mailbox.poll(5, TimeUnit.SECONDS)!!.invoke(); expect(applied == 1 && !runner.busy)
    } finally { release.countDown(); runner.close(); worker.shutdown(); expect(worker.awaitTermination(5, TimeUnit.SECONDS)) }
}
class AirImportRunnerTest {
    @Test fun allOperationFamilies() { AirImportLifecycle.Kind.entries.forEach(::perKind) }
    @Test fun blockedWorkerCannotQueueRestarts() { realExecutor() }
}
