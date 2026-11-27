import Testing
@testable import NoSpeakerCore

struct NativeHelperRelativePartialStopDebtTests {
    @MainActor private final class Service {
        var gates = LegacyGateReleaseDebt()
        var controllers = LegacyControllerReleaseDebt()
        var attempts: [Int] = []
        var retireCount = 0
        var finishCount = 0

        init(channel: Int) {
            gates.record(.init(0x90 | channel, 60, 90), succeeded: true)
            gates.record(.init(0xb0 | channel, 64, 127), succeeded: true)
            controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: true)
            controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: true)
            controllers.beginRange(channel: channel)
        }

        var pendingMask: Int {
            var mask = 0
            for message in gates.pending { mask |= message.status & 0xf0 == 0x80 ? 1 : 2 }
            for message in controllers.pending { mask |= message.status & 0xf0 == 0xe0 ? 4 : 8 }
            if !controllers.pendingRanges.isEmpty { mask |= 16 }
            return mask
        }

        func stop(failedMask: Int) {
            attempts = []
            for message in gates.pending {
                let bit = message.status & 0xf0 == 0x80 ? 1 : 2
                attempts.append(bit)
                gates.record(message, succeeded: failedMask & bit == 0)
            }
            for channel in controllers.pendingRanges {
                attempts.append(16)
                if failedMask & 16 == 0 { controllers.completeRange(channel: channel) }
            }
            for message in controllers.pending {
                let bend = message.status & 0xf0 == 0xe0
                let bit = bend ? 4 : 8
                attempts.append(bit)
                controllers.record(message, neutral: bend ? 8192 : message.data2,
                    succeeded: failedMask & bit == 0)
            }
        }

        func finish() -> Bool {
            finishCount += 1
            let pending = !LegacyRecoveryPolicy.permitsReplacement(gatesPending: !gates.isEmpty,
                controllersPending: !controllers.isEmpty, unknownFailure: false)
            return NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(reservationsEmpty: true,
                transportReady: false, shutdownCleanupPending: pending, recoveryRequired: false)
        }
    }

    @Test(arguments: Array(0...15)) @MainActor
    func mixedCleanupRetriesOnlyOutstandingDebt(channel: Int) throws {
        for initialFailure in 1...30 {
            let original = Service(channel: channel)
            let replacement = Service(channel: channel)
            let slot = NativeHelperRelativeHostLifetime<Service>()
            let token = try #require(slot.install(original))
            original.stop(failedMask: initialFailure)
            #expect(original.attempts == [2, 1, 16, 8, 4])
            #expect(original.pendingMask == initialFailure)
            let closed = slot.close(token, retire: { $0.retireCount += 1 }, finish: { $0.finish() })
            #expect(!closed)
            #expect(slot.phase == .closing)
            #expect(slot.install(replacement) == nil)
            var remaining = initialFailure
            while remaining != 0 {
                let one = remaining & -remaining
                let next = remaining & ~one
                original.stop(failedMask: next)
                #expect(original.attempts == [2, 1, 16, 8, 4].filter { remaining & $0 != 0 })
                #expect(original.pendingMask == next)
                let finished = slot.retry(token, finish: { $0.finish() })
                #expect(finished == (next == 0))
                #expect(slot.phase == (next == 0 ? .idle : .closing))
                remaining = next
            }
            #expect(original.retireCount == 1)
            #expect(original.finishCount == 1 + initialFailure.nonzeroBitCount)
            original.stop(failedMask: 31)
            #expect(original.attempts.isEmpty)
            #expect(original.pendingMask == 0)
            let fresh = try #require(slot.install(replacement))
            let stale = slot.retry(token, finish: { $0.finish() })
            #expect(!stale)
            #expect(slot.activeHost(for: fresh) === replacement)
            #expect(replacement.finishCount == 0)
        }
    }
}
