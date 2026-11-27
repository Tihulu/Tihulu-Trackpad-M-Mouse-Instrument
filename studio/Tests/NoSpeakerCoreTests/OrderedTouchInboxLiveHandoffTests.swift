import Dispatch
import Foundation
import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxLiveHandoffTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // A semaphore wait must not occupy a cooperative Swift Testing worker.
    // Use independent threads for the blocking producer and bounded waits;
    // assertions still run in the original asynchronous test task.
    private func waitOffExecutor(_ wait: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: wait()) }
        }
    }

    // One producer and one serialized consumer run simultaneously. A wave
    // acknowledgement bounds outstanding input; no assumption about thread
    // scheduling or how many batches a wave will require.
    @Test(arguments: [1, 4, 16, 32], [1, 8, 32])
    func liveProducerConsumerHandoff(waveSize: Int, waves: Int) async {
        let inbox = OrderedTouchInbox<Int>()
        let callback = DispatchSemaphore(value: 0)
        let acknowledgement = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let requested = Counter()
        let producerTimeouts = Counter()
        finished.enter()
        Thread.detachNewThread {
            defer { finished.leave() }
            for wave in 0..<waves {
                for index in 0..<waveSize {
                    if inbox.submit(wave * waveSize + index) {
                        requested.increment()
                        callback.signal()
                    }
                }
                if acknowledgement.wait(timeout: .now() + 5) != .success {
                    producerTimeouts.increment()
                    return
                }
            }
        }
        var received: [Int] = []
        var callbackCount = 0
        var previous: OrderedTouchInbox<Int>.Batch?
        func drain() async {
            while received.count < waveSize * waves {
                let signalled = await waitOffExecutor { callback.wait(timeout: .now() + 5) == .success }
                guard signalled else {
                    Issue.record("Producer scheduling handoff lost")
                    return
                }
                callbackCount += 1
                while true {
                    let batch = inbox.take()
                    guard !batch.overflow, !batch.samples.isEmpty else {
                        Issue.record("Unexpected empty or overflow callback")
                        return
                    }
                    #expect(inbox.permits(batch))
                    if let previous { #expect(!inbox.permits(previous)) }
                    previous = batch
                    received.append(contentsOf: batch.samples)
                    if received.count.isMultiple(of: waveSize) { acknowledgement.signal() }
                    if !batch.more { break }
                }
            }
            let producerFinished = await waitOffExecutor { finished.wait(timeout: .now() + 5) == .success }
            #expect(producerFinished)
            #expect(producerTimeouts.value == 0)
            #expect(received == Array(0..<(waveSize * waves)))
            #expect(callbackCount == requested.value)
            let noExtraCallback = await waitOffExecutor { callback.wait(timeout: .now()) == .timedOut }
            #expect(noExtraCallback)
            #expect(inbox.take().samples.isEmpty)
            if let previous { #expect(inbox.permits(previous)) }
            inbox.close()
            if let previous { #expect(!inbox.permits(previous)) }
            #expect(!inbox.submit(-1))
        }
        await drain()
        inbox.close()
        acknowledgement.signal()
        let joined = await waitOffExecutor { finished.wait(timeout: .now() + 6) == .success }
        #expect(joined)
    }

    // Closing while producers are released together must revoke the old
    // consumer admission and prevent any subsequent delivery. Submissions
    // that linearize before close may legitimately schedule a callback.
    @Test(arguments: [2, 4, 8])
    func closeRacingWithProducers(producers: Int) {
        for _ in 0..<16 {
            let inbox = OrderedTouchInbox<Int>()
            #expect(inbox.submit(-1))
            let active = inbox.take()
            #expect(inbox.permits(active))
            DispatchQueue.concurrentPerform(iterations: producers + 1) { index in
                if index == producers { inbox.close() }
                else { for value in 0..<16 { _ = inbox.submit(index * 16 + value) } }
            }
            #expect(!inbox.permits(active))
            #expect(!inbox.acknowledgeOverflow(after: active))
            #expect(!inbox.submit(999))
            let closed = inbox.take()
            #expect(closed.samples.isEmpty && !closed.overflow && !closed.more)
            #expect(!inbox.permits(closed))
        }
    }
}
