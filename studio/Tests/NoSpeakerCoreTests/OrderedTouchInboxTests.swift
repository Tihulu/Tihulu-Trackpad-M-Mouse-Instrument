import Testing
@testable import NoSpeakerCore

@Test func orderedTouchInboxKeepsEveryShortTapInCommittedOrder() {
    let inbox = OrderedTouchInbox<Int>()
    var scheduled = 0
    for i in 0..<64 {
        if inbox.submit(i) { scheduled += 1 }
    }
    #expect(scheduled == 1)
    var received: [Int] = []
    for i in 0..<4 {
        let batch = inbox.take()
        #expect(!batch.overflow)
        #expect(batch.samples.count == 16)
        #expect(batch.more == (i < 3))
        received += batch.samples
    }
    #expect(received == Array(0..<64))
    #expect(inbox.submit(64))
    #expect(inbox.take().samples == [64])
}

@Test func orderedTouchInboxRejectsEntireOverflowBatchAndCanRecover() {
    let inbox = OrderedTouchInbox<Int>()
    for i in 0..<65 { _ = inbox.submit(i) }
    #expect(!inbox.submit(65))
    let failed = inbox.take()
    #expect(failed.overflow)
    #expect(failed.samples.isEmpty)
    #expect(!failed.more)
    #expect(inbox.submit(100))
    let recovered = inbox.take()
    #expect(!recovered.overflow)
    #expect(recovered.samples == [100])
}

@Test func orderedTouchInboxTransfersSchedulingWhenDrainBecomesEmpty() {
    let inbox = OrderedTouchInbox<Int>()
    #expect(inbox.submit(0))
    for i in 1..<20 { #expect(!inbox.submit(i)) }
    let first = inbox.take()
    #expect(first.samples == Array(0..<16))
    #expect(first.more)
    #expect(!inbox.submit(20))
    let second = inbox.take()
    #expect(second.samples == Array(16...20))
    #expect(!second.more)
    #expect(inbox.submit(21))
    #expect(inbox.take().samples == [21])
}

@Test func orderedTouchInboxCloseFencesPendingAndLateCallbacks() {
    let inbox = OrderedTouchInbox<Int>()
    #expect(inbox.submit(1))
    inbox.close()
    #expect(!inbox.submit(2))
    let batch = inbox.take()
    #expect(batch.samples.isEmpty)
    #expect(!batch.more)
    #expect(!batch.overflow)
}

@Test func orderedTouchInboxRepeatedBurstsPreserveTenThousandEdges() {
    let inbox = OrderedTouchInbox<Int>()
    var expected = 0
    for start in stride(from:0,to:10_000,by:20) {
        for i in start..<(start+20) { _ = inbox.submit(i) }
        var more = true
        while more {
            let batch = inbox.take()
            #expect(!batch.overflow)
            for sample in batch.samples {
                #expect(sample == expected)
                expected += 1
            }
            more = batch.more
        }
    }
    #expect(expected == 10_000)
}
