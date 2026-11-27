import Testing
@testable import NoSpeakerCore

struct OrderedTouchInboxModelTraceTests {
    private struct Oracle {
        struct Ticket {
            let data: [Int]
            let fault: Bool
            let more: Bool
            let epoch: Int
            let serial: Int
        }
        var queued: [Int] = []
        var callbackOwned = false
        var failedEpoch: Int?
        var closed = false
        var epoch = 0
        var serial = 0
        var latestDataSerial = 0

        mutating func submit(_ value: Int) -> Bool {
            if closed || failedEpoch != nil { return false }
            queued.append(value)
            if queued.count > 64 {
                failedEpoch = epoch
                epoch += 1
                queued = []
            }
            let needsCallback = !callbackOwned
            callbackOwned = true
            return needsCallback
        }
        mutating func take() -> Ticket {
            serial += 1
            let fault = failedEpoch != nil && !closed
            let data = (closed || fault) ? [] : Array(queued.prefix(16))
            if closed || fault { queued = []; failedEpoch = nil }
            else { queued = Array(queued.dropFirst(data.count)) }
            callbackOwned = !queued.isEmpty
            if !data.isEmpty { latestDataSerial = serial }
            return Ticket(data: data, fault: fault, more: callbackOwned, epoch: epoch, serial: serial)
        }
        func permits(_ ticket: Ticket) -> Bool {
            !closed && failedEpoch == nil && !ticket.data.isEmpty &&
            !ticket.fault && ticket.epoch == epoch && ticket.serial == latestDataSerial
        }
        mutating func acknowledge(_ ticket: Ticket) -> Bool {
            if closed || ticket.data.isEmpty || ticket.fault ||
                failedEpoch != ticket.epoch || ticket.serial != serial { return false }
            failedEpoch = nil
            callbackOwned = !ticket.more
            return true
        }
        mutating func close() {
            closed = true; queued = []; failedEpoch = nil; callbackOwned = false
        }
    }

    private struct Generator {
        var state: UInt64
        mutating func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
    }

    // Reproducible operation sequences, independent of thread scheduling.
    // Overflow may be handled by the scheduled drain or by its active owner.
    @Test(arguments: Array(1...32))
    func seededStateTrace(seed: Int) {
        let inbox = OrderedTouchInbox<Int>()
        let foreign = OrderedTouchInbox<Int>()
        _ = foreign.submit(-1)
        let foreignBatch = foreign.take()
        var model = Oracle()
        var generator = Generator(state: UInt64(seed))
        var history: [(OrderedTouchInbox<Int>.Batch, Oracle.Ticket)] = []
        var value = 0
        for step in 0..<256 {
            let op = generator.next(10)
            switch op {
            case 0...4:
                let count = [1, 2, 16, 64, 65][op]
                for _ in 0..<count {
                    let expected = model.submit(value)
                    #expect(inbox.submit(value) == expected, "seed \(seed) step \(step) submit \(value)")
                    value += 1
                }
            case 5, 6:
                let actual = inbox.take()
                let expected = model.take()
                #expect(actual.samples == expected.data)
                #expect(actual.overflow == expected.fault)
                #expect(actual.more == expected.more)
                history.append((actual, expected))
            case 7:
                if !history.isEmpty {
                    let selected = history[generator.next(history.count)]
                    let expected = model.acknowledge(selected.1)
                    #expect(inbox.acknowledgeOverflow(after: selected.0) == expected)
                }
            case 8:
                if let latest = history.last {
                    let expected = model.acknowledge(latest.1)
                    #expect(inbox.acknowledgeOverflow(after: latest.0) == expected)
                }
            default:
                if step >= 224 { inbox.close(); model.close() }
            }
            #expect(!inbox.permits(foreignBatch))
            #expect(!inbox.acknowledgeOverflow(after: foreignBatch))
            for entry in history.suffix(8) {
                #expect(inbox.permits(entry.0) == model.permits(entry.1), "seed \(seed) step \(step) admission")
            }
        }
        inbox.close(); model.close()
        #expect(!inbox.submit(value))
        #expect(inbox.take().samples.isEmpty)
        for entry in history {
            #expect(!inbox.permits(entry.0))
            #expect(!inbox.acknowledgeOverflow(after: entry.0))
        }
    }
}
