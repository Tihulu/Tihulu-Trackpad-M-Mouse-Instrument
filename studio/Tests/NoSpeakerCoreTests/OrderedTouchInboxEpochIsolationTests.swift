import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxEpochIsolationTests {
    // Identical payloads and drain serials must never authorize a foreign
    // inbox. Overflow invalidates the previous epoch even after recovery.
    @Test(arguments: [1, 16, 17, 32, 64], [1, 4, 8])
    func foreignBatchesAndRepeatedOverflowRecovery(count: Int, cycles: Int) {
        typealias Batch = OrderedTouchInbox<Int>.Batch
        let first = OrderedTouchInbox<Int>()
        let second = OrderedTouchInbox<Int>()
        var staleFirst: [Batch] = []
        var staleSecond: [Batch] = []
        for cycle in 0..<cycles {
            for value in 0..<count {
                #expect(first.submit(value) == (value == 0))
                #expect(second.submit(value) == (value == 0))
            }
            let a = first.take(), b = second.take()
            #expect(a.samples == b.samples)
            #expect(a.more == b.more)
            #expect(first.permits(a) && second.permits(b))
            #expect(!first.permits(b) && !second.permits(a))
            for old in staleFirst + staleSecond {
                #expect(!first.permits(old) && !second.permits(old))
            }
            for value in 100..<165 {
                let schedules = value == 100 && !a.more
                #expect(first.submit(value) == schedules)
                #expect(second.submit(value) == schedules)
            }
            #expect(!first.permits(a) && !second.permits(b))
            #expect(!first.acknowledgeOverflow(after: b))
            #expect(!second.acknowledgeOverflow(after: a))
            for old in staleFirst + staleSecond {
                #expect(!first.acknowledgeOverflow(after: old))
                #expect(!second.acknowledgeOverflow(after: old))
            }
            #expect(first.acknowledgeOverflow(after: a))
            #expect(!first.acknowledgeOverflow(after: a))
            #expect(!second.permits(b))
            #expect(second.acknowledgeOverflow(after: b))
            #expect(!second.acknowledgeOverflow(after: b))
            #expect(first.submit(1000 + cycle) == a.more)
            #expect(second.submit(1000 + cycle) == b.more)
            let recoveredA = first.take(), recoveredB = second.take()
            #expect(recoveredA.samples == [1000 + cycle])
            #expect(recoveredB.samples == recoveredA.samples)
            #expect(!recoveredA.overflow && !recoveredB.overflow)
            #expect(first.permits(recoveredA) && second.permits(recoveredB))
            #expect(!first.permits(recoveredB) && !second.permits(recoveredA))
            #expect(!first.permits(a) && !second.permits(b))
            staleFirst += [a, recoveredA]
            staleSecond += [b, recoveredB]
        }
        first.close()
        #expect(!first.submit(-1))
        for old in staleFirst + staleSecond { #expect(!first.permits(old)) }
        #expect(second.submit(-1))
        let surviving = second.take()
        #expect(surviving.samples == [-1] && second.permits(surviving))
        #expect(!first.permits(surviving))
        second.close()
        #expect(!second.permits(surviving))
    }
}
