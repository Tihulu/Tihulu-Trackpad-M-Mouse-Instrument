import Testing
@testable import NoSpeakerCore

struct LegacyBendRangeRecoveryTests {
    private struct Part: Equatable {
        let cc: Int
        let value: Int
    }

    @Test(arguments: Array(0...15))
    func incompleteDataEntryRemainsUnknownAfterNullCleanup(channel: Int) {
        for semitones in [Int.min, -1, 0, 12, 24, 25, Int.max] {
            let value = max(0, min(24, semitones))
            let expected = [Part(cc: 101, value: 0), Part(cc: 100, value: 0),
                Part(cc: 6, value: value), Part(cc: 38, value: 0),
                Part(cc: 101, value: 127), Part(cc: 100, value: 127)]
            for failAt in 0...6 {
                var debt = LegacyControllerReleaseDebt()
                var observed: [Part] = []
                debt.beginRange(channel: channel)
                let result = LegacyRecoveryPolicy.sendLegacyBendRange(semitones: semitones) { cc, value in
                    observed.append(.init(cc: cc, value: value))
                    return observed.count - 1 != failAt
                }
                if result.completed { debt.completeRange(channel: channel) }
                let manualRecovery = (2...5).contains(failAt)
                #expect(observed == Array(expected.prefix(min(6, failAt + 1))))
                #expect(result.completed == (failAt == 6))
                #expect(result.dataAttempted == (failAt >= 2))
                #expect(result.requiresManualRecovery == manualRecovery)
                #expect(debt.pendingRanges == (failAt == 6 ? [] : [channel]))
                var cleanup: [LegacyGateReleaseDebt.Message] = []
                LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { [] },
                    pendingRanges: { debt.pendingRanges }, pendingControllers: { debt.pending },
                    send: { message, neutral, range in
                        #expect(neutral == nil)
                        #expect(range)
                        cleanup.append(message)
                        return true
                    }, completeRange: { debt.completeRange(channel: $0) })
                #expect(cleanup == (failAt == 6 ? [] : [.init(0xb0 | channel, 101, 127), .init(0xb0 | channel, 100, 127)]))
                #expect(debt.isEmpty)
                #expect(LegacyRecoveryPolicy.permitsReplacement(gatesPending: false,
                    controllersPending: !debt.isEmpty, unknownFailure: result.requiresManualRecovery) == !manualRecovery)
                #expect(LegacyRecoveryPolicy.permitsActiveStart(faulted: false,
                    unknownFailure: result.requiresManualRecovery, cleaning: false) == !manualRecovery)
            }
        }
    }
}
