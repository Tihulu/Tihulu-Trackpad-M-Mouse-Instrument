import Testing
@testable import NoSpeakerCore

@Test func orderedTouchRepeatedOverflowPreservesExactlyOneScheduledConsumer() {
    // Cover all initial queue sizes and all legal drain prefixes. The
    // serialized consumer holds the current batch while producers refill.
    for initial in 1...64 {
        for prefix in 1...((initial + 15) / 16) {
            let inbox = OrderedTouchInbox<Int>()
            for i in 0..<initial { #expect(inbox.submit(i) == (i == 0)) }
            var batch = inbox.take()
            if prefix > 1 {
                for _ in 1..<prefix { batch = inbox.take() }
            }
            let pending = max(0, initial - prefix * 16)
            #expect(batch.more == (pending > 0))
            #expect(inbox.permits(batch))
            var scheduled = batch.more ? 0 : 1
            // If the queue was empty the first producer owns the callback.
            for i in 0..<(65 - pending) {
                #expect(inbox.submit(100 + i) == (!batch.more && i == 0))
            }
            #expect(!inbox.permits(batch))
            #expect(inbox.acknowledgeOverflow(after: batch))
            // A partial drain relinquishes its own continuation. An empty
            // drain preserves the callback already scheduled by a producer.
            for i in 0..<65 {
                if inbox.submit(200 + i) { scheduled += 1 }
            }
            #expect(scheduled == 1)
            #expect(!inbox.acknowledgeOverflow(after: batch))
            #expect(!inbox.permits(batch))
            let secondFault = inbox.take()
            #expect(secondFault.overflow && secondFault.samples.isEmpty && !secondFault.more)
            #expect(!inbox.permits(secondFault))
            #expect(inbox.submit(300))
            let fresh = inbox.take()
            #expect(fresh.samples == [300] && inbox.permits(fresh))
            #expect(!inbox.permits(batch))
        }
    }
}

@Test func orderedTouchRepeatedOverflowDoesNotReviveAnyRetiredBatch() {
    let inbox = OrderedTouchInbox<Int>()
    var retired: [OrderedTouchInbox<Int>.Batch] = []
    for cycle in 0..<32 {
        #expect(inbox.submit(cycle))
        let batch = inbox.take()
        #expect(inbox.permits(batch))
        for previous in retired { #expect(!inbox.permits(previous)) }
        for i in 0..<65 { #expect(inbox.submit(100 + i) == (i == 0)) }
        #expect(inbox.acknowledgeOverflow(after: batch))
        retired.append(batch)
        for previous in retired { #expect(!inbox.permits(previous)) }
        // The outstanding producer callback sees an empty, healthy queue.
        let empty = inbox.take()
        #expect(!empty.overflow && empty.samples.isEmpty && !empty.more)
        #expect(!inbox.permits(empty))
    }
    inbox.close()
    for previous in retired { #expect(!inbox.permits(previous)) }
}
