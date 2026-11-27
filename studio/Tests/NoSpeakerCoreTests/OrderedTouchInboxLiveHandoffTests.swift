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

    // One producer and one serialized consumer run simultaneously. A wave
    // acknowledgement bounds outstanding input; no assumption about thread
    // scheduling or how many batches a wave will require.
    @Test(arguments: [1, 4, 16, 32], [1, 8, 32])
    func liveProducerConsumerHandoff(waveSize: Int, waves: Int) {
        let inbox = OrderedTouchInbox<Int>()
        let callback = DispatchSemaphore(value: 0)
        let acknowledgement = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let requested = Counter()
        let producerTimeouts = Counter()
        finished.enter()
        DispatchQueue.global().async {
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
        defer {
            inbox.close()
            acknowledgement.signal()
            #expect(finished.wait(timeout: .now() + 6) == .success)
        }
        while received.count < waveSize * waves {
            guard callback.wait(timeout: .now() + 5) == .success else {
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
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(producerTimeouts.value == 0)
        #expect(received == Array(0..<(waveSize * waves)))
        #expect(callbackCount == requested.value)
        #expect(callback.wait(timeout: .now()) == .timedOut)
        #expect(inbox.take().samples.isEmpty)
        if let previous { #expect(inbox.permits(previous)) }
        inbox.close()
        if let previous { #expect(!inbox.permits(previous)) }
        #expect(!inbox.submit(-1))
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
