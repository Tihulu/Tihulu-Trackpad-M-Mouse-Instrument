import Foundation
import Testing
@testable import NoSpeakerCore

@Test func orderedTouchAdmissionInvalidatesDrainedBatchOnOverflow() {
    let inbox = OrderedTouchInbox<Int>()
    #expect(inbox.submit(0))
    let old = inbox.take()
    #expect(inbox.permits(old))
    for i in 1...64 { _ = inbox.submit(i) }
    #expect(inbox.permits(old))
    _ = inbox.submit(65)
    #expect(!inbox.permits(old))
    let fault = inbox.take()
    #expect(fault.overflow)
    #expect(!inbox.permits(fault))
    #expect(!inbox.permits(old))
    #expect(inbox.submit(66))
    let fresh = inbox.take()
    #expect(inbox.permits(fresh))
    #expect(fresh.samples == [66])
    #expect(!inbox.permits(old))
}

@Test func orderedTouchAdmissionRejectsForeignEmptyAndClosedBatches() {
    let inbox = OrderedTouchInbox<Int>()
    let foreign = OrderedTouchInbox<Int>()
    _ = inbox.submit(1)
    _ = foreign.submit(2)
    let old = inbox.take()
    #expect(!inbox.permits(foreign.take()))
    #expect(!inbox.permits(inbox.take()))
    #expect(inbox.permits(old))
    inbox.close()
    #expect(!inbox.permits(old))
    #expect(!inbox.submit(3))
    #expect(!inbox.permits(inbox.take()))
}

@Test func orderedTouchAdmissionHealthyDrainsKeepFIFOAndScheduling() {
    let inbox = OrderedTouchInbox<Int>()
    for i in 0..<64 { #expect(inbox.submit(i) == (i == 0)) }
    var received: [Int] = []
    for i in 0..<4 {
        let batch = inbox.take()
        #expect(inbox.permits(batch))
        #expect(batch.more == (i < 3))
        received += batch.samples
    }
    #expect(received == Array(0..<64))
    #expect(inbox.submit(64))
    #expect(inbox.permits(inbox.take()))
}

@Test func orderedTouchAdmissionConcurrentProducersCannotReviveOldBatch() {
    let inbox = OrderedTouchInbox<Int>()
    _ = inbox.submit(-1)
    let old = inbox.take()
    DispatchQueue.concurrentPerform(iterations: 64) { i in _ = inbox.submit(i) }
    #expect(inbox.permits(old))
    DispatchQueue.concurrentPerform(iterations: 8) { i in _ = inbox.submit(64 + i) }
    #expect(!inbox.permits(old))
    #expect(inbox.take().overflow)
    DispatchQueue.concurrentPerform(iterations: 64) { i in _ = inbox.submit(i) }
    var received: [Int] = []
    for _ in 0..<4 {
        let batch = inbox.take()
        #expect(inbox.permits(batch))
        received += batch.samples
    }
    #expect(received.sorted() == Array(0..<64))
    #expect(!inbox.permits(old))
}
