import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxDrainIdentityTests {
    @Test(arguments: Array(1...64))
    func latestDrainOnly(count: Int) {
        let inbox = OrderedTouchInbox<Int>()
        var scheduled = 0
        for value in 0..<count { if inbox.submit(value) { scheduled += 1 } }
        #expect(scheduled == 1)
        var older: [OrderedTouchInbox<Int>.Batch] = []
        var received: [Int] = []
        while true {
            let batch = inbox.take()
            #expect(inbox.permits(batch))
            for previous in older { #expect(!inbox.permits(previous)) }
            received += batch.samples
            older.append(batch)
            if !batch.more { break }
        }
        #expect(received == Array(0..<count))
        #expect(inbox.submit(100))
        let next = inbox.take()
        #expect(inbox.permits(next))
        for previous in older { #expect(!inbox.permits(previous)) }
        let empty = inbox.take()
        #expect(!inbox.permits(empty))
        #expect(!inbox.permits(next))
        inbox.close()
        #expect(!inbox.permits(next))
    }

    @Test(arguments: [1, 16, 17, 32, 64])
    func overflowOwnershipUnchanged(count: Int) {
        let inbox = OrderedTouchInbox<Int>()
        for value in 0..<count { _ = inbox.submit(value) }
        let batch = inbox.take()
        #expect(inbox.permits(batch))
        var scheduled = 0
        for value in 100..<165 { if inbox.submit(value) { scheduled += 1 } }
        #expect(scheduled == (batch.more ? 0 : 1))
        #expect(!inbox.permits(batch))
        #expect(inbox.acknowledgeOverflow(after: batch))
        #expect(!inbox.acknowledgeOverflow(after: batch))
        #expect(inbox.submit(200) == batch.more)
        let recovered = inbox.take()
        #expect(recovered.samples == [200])
        #expect(inbox.permits(recovered))
        #expect(!inbox.permits(batch))
    }
}
