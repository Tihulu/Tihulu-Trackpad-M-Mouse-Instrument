import Testing
@testable import NoSpeakerCore

/// Forget only the explicitly persistent gain, never a neighboring channel,
/// another controller, or the pending recovery state of the transport.
@Test(arguments: Array(0..<16), [7, 11])
func legacyPersistentGainIsolatesCleanupDebt(channel: Int, gain: Int) {
    typealias Message = LegacyGateReleaseDebt.Message
    var debt = LegacyControllerReleaseDebt()
    var expected: [Message] = []
    for ch in 0..<16 {
        for cc in [7, 11, 74] {
            let neutral = cc == 74 ? ch : 127
            debt.record(.init(0xb0 | ch, cc, 60), neutral: neutral, succeeded: ch.isMultiple(of: 2))
            expected.append(.init(0xb0 | ch, cc, neutral))
        }
    }
    for ch in 0..<16 {
        debt.record(.init(0xd0 | ch, gain, 0), neutral: 0, succeeded: false)
        expected.append(.init(0xd0 | ch, 0, 0))
    }
    for ch in 0..<16 {
        debt.record(.init(0xe0 | ch, gain, 65), neutral: 8192, succeeded: false)
        expected.append(.init(0xe0 | ch, 0, 64))
        debt.beginRange(channel: ch)
    }
    #expect(debt.pending == expected)
    #expect(debt.pendingRanges == Array(0..<16))
    // Unsupported kinds and ordinary CCs must never erase obligations.
    for message in [Message(0xb0 | channel, 74, 50),
                    .init(0xd0 | channel, gain, 0),
                    .init(0xe0 | channel, gain, 65),
                    .init(0x90 | channel, gain, 90)] {
        debt.forgetPersistentGain(message)
        #expect(debt.pending == expected)
    }
    let persistent = Message(0xb0 | channel, gain, 99)
    for _ in 0..<2 { debt.forgetPersistentGain(persistent) }
    expected.removeAll { $0.status == persistent.status && $0.data1 == persistent.data1 }
    #expect(debt.pending == expected)
    #expect(debt.pendingRanges == Array(0..<16))
    var attempted: [Message] = []
    var completed: [Int] = []
    for retry in 0..<2 {
        attempted.removeAll()
        completed.removeAll()
        let selectors = (0..<16).flatMap { ch in
            [Message(0xb0 | ch, 101, 127), .init(0xb0 | ch, 100, 127)]
        }
        let expectedWire = selectors + expected
        LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { [] },
            pendingRanges: { debt.pendingRanges }, pendingControllers: { debt.pending },
            send: { message, neutral, range in
                attempted.append(message)
                let success = retry == 1
                if !range, let neutral { debt.record(message, neutral: neutral, succeeded: success) }
                return success
            }, completeRange: { ch in
                completed.append(ch)
                debt.completeRange(channel: ch)
            })
        #expect(attempted == expectedWire)
        #expect(!attempted.contains { $0.status == persistent.status && $0.data1 == persistent.data1 })
        #expect(completed == (retry == 0 ? [] : Array(0..<16)))
        #expect(debt.pending == (retry == 0 ? expected : []))
        #expect(debt.pendingRanges == (retry == 0 ? Array(0..<16) : []))
        #expect(!LegacyRecoveryPolicy.permitsReplacement(gatesPending: false,
            controllersPending: !debt.isEmpty, unknownFailure: true))
        #expect(!LegacyRecoveryPolicy.permitsSend(enabled: true, faulted: false,
            cleaning: false, unknownFailure: true))
    }
    #expect(debt.isEmpty)
    // A later ordinary gain write is tracked again; forgetting was not a global opt-out.
    debt.record(persistent, neutral: 127, succeeded: true)
    #expect(debt.pending == [Message(persistent.status, gain, 127)])
    debt.record(.init(persistent.status, gain, 127), neutral: 127, succeeded: true)
    #expect(debt.isEmpty)
}
