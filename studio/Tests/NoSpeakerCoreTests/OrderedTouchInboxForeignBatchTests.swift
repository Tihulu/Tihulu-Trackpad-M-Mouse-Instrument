import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxForeignBatchTests {
    @Test(arguments: [1, 16, 17, 32], [1, 16, 17, 32])
    func foreignAndRetiredBatchesCannotClearOverflow(firstCount: Int, secondCount: Int) {
        let first = OrderedTouchInbox<Int>()
        let second = OrderedTouchInbox<Int>()
        for index in 0..<firstCount { _ = first.submit(index) }
        for index in 0..<secondCount { _ = second.submit(index) }
        let firstBatch = first.take()
        let secondBatch = second.take()
        #expect(first.permits(firstBatch))
        #expect(second.permits(secondBatch))
        #expect(!first.permits(secondBatch))
        #expect(!second.permits(firstBatch))

        func overflow(_ inbox: OrderedTouchInbox<Int>) {
            for index in 0..<65 { _ = inbox.submit(100 + index) }
        }
        overflow(first)
        overflow(second)
        #expect(!first.permits(firstBatch))
        #expect(!second.permits(secondBatch))
        #expect(!first.acknowledgeOverflow(after: secondBatch))
        #expect(!second.acknowledgeOverflow(after: firstBatch))
        #expect(!first.submit(-1))
        #expect(!second.submit(-1))

        #expect(first.acknowledgeOverflow(after: firstBatch))
        #expect(!second.submit(-2))
        #expect(second.acknowledgeOverflow(after: secondBatch))
        #expect(first.submit(1000) == firstBatch.more)
        #expect(second.submit(2000) == secondBatch.more)
        let firstRecovered = first.take()
        let secondRecovered = second.take()
        #expect(firstRecovered.samples == [1000])
        #expect(secondRecovered.samples == [2000])
        #expect(!firstRecovered.overflow && !secondRecovered.overflow)
        #expect(first.permits(firstRecovered))
        #expect(second.permits(secondRecovered))
        #expect(!first.permits(firstBatch))
        #expect(!second.permits(secondBatch))

        overflow(first)
        overflow(second)
        #expect(!first.acknowledgeOverflow(after: firstBatch))
        #expect(!second.acknowledgeOverflow(after: secondBatch))
        #expect(!first.acknowledgeOverflow(after: secondRecovered))
        #expect(!second.acknowledgeOverflow(after: firstRecovered))
        #expect(first.acknowledgeOverflow(after: firstRecovered))
        #expect(second.acknowledgeOverflow(after: secondRecovered))
        #expect(!first.submit(3000))
        #expect(!second.submit(4000))
        #expect(first.take().samples == [3000])
        #expect(second.take().samples == [4000])
    }
}
