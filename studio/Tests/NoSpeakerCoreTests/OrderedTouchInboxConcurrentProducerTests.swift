import Foundation
import Dispatch
import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxConcurrentProducerTests {
    private final class ScheduleCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // Joining producers before a single consumer drains gives a deterministic
    // assertion boundary without requiring any particular cross-producer order.
    private func submitWave(_ inbox: OrderedTouchInbox<Int>, producers: Int,
                            perProducer: Int, offset: Int = 0) -> Int {
        let schedules = ScheduleCounter()
        DispatchQueue.concurrentPerform(iterations: producers) { producer in
            for index in 0..<perProducer {
                if inbox.submit(offset + producer * perProducer + index) {
                    schedules.increment()
                }
            }
        }
        return schedules.value
    }

    @Test(arguments: [2, 4, 8], [1, 2, 4, 8])
    func concurrentProducerWavesPreserveFIFOAndLatestAdmission(producers: Int, perProducer: Int) {
        let inbox = OrderedTouchInbox<Int>()
        let total = producers * perProducer
        var previous: OrderedTouchInbox<Int>.Batch?
        for wave in 0..<8 {
            let offset = wave * total
            #expect(submitWave(inbox, producers: producers, perProducer: perProducer, offset: offset) == 1)
            var received: [Int] = []
            while true {
                let batch = inbox.take()
                #expect(inbox.permits(batch))
                #expect(!batch.overflow)
                if let previous { #expect(!inbox.permits(previous)) }
                received += batch.samples
                previous = batch
                if !batch.more { break }
            }
            #expect(received.sorted() == Array(offset..<(offset + total)))
            for producer in 0..<producers {
                let start = offset + producer * perProducer
                #expect(received.filter { (start..<(start + perProducer)).contains($0) } == Array(start..<(start + perProducer)))
            }
            #expect(!inbox.permits(inbox.take()))
            if let previous { #expect(inbox.permits(previous)) }
        }
        inbox.close()
        #expect(submitWave(inbox, producers: producers, perProducer: perProducer) == 0)
        if let previous { #expect(!inbox.permits(previous)) }
        #expect(inbox.take().samples.isEmpty)
    }

    @Test(arguments: [2, 4, 8], [false, true])
    func concurrentOverflowPreservesSchedulingAndRecovery(producers: Int, hadMore: Bool) {
        for _ in 0..<8 {
            let inbox = OrderedTouchInbox<Int>()
            for value in 0..<(hadMore ? 17 : 1) { _ = inbox.submit(value) }
            let active = inbox.take()
            #expect(active.more == hadMore)
            #expect(inbox.permits(active))
            // More than 64 new samples guarantees overflow even with an
            // initially empty pending queue, regardless of producer order.
            #expect(submitWave(inbox, producers: producers, perProducer: 65 / producers + 1, offset: 100) == (hadMore ? 0 : 1))
            #expect(!inbox.permits(active))
            #expect(inbox.acknowledgeOverflow(after: active))
            #expect(!inbox.acknowledgeOverflow(after: active))
            #expect(inbox.submit(999) == hadMore)
            let recovered = inbox.take()
            #expect(recovered.samples == [999])
            #expect(!recovered.overflow)
            #expect(inbox.permits(recovered))
            #expect(!inbox.permits(active))
            inbox.close()
            #expect(!inbox.permits(recovered))
        }
    }
}
