import Testing
@testable import NoSpeakerCore

struct NativeHelperRelativeFullStopDebtTests {
    @MainActor private final class Service {
        var gates = LegacyGateReleaseDebt()
        var controllers = LegacyControllerReleaseDebt()
        var unknownFailure = false
        var transportReady = true
        var reservationsEmpty = false
        var retireCalls = 0
        var finishCalls = 0

        var pending: Bool {
            !LegacyRecoveryPolicy.permitsReplacement(gatesPending: !gates.isEmpty,
                controllersPending: !controllers.isEmpty, unknownFailure: unknownFailure)
        }
        func finish() -> Bool {
            finishCalls += 1
            return NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(
                reservationsEmpty: reservationsEmpty, transportReady: transportReady,
                shutdownCleanupPending: pending, recoveryRequired: unknownFailure)
        }
        func seed(channel: Int, mask: Int, succeeded: Bool) {
            if mask & 1 != 0 { gates.record(.init(0x90 | channel, 60, 90), succeeded: succeeded) }
            if mask & 2 != 0 { gates.record(.init(0xb0 | channel, 64, 127), succeeded: succeeded) }
            if mask & 4 != 0 { controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: succeeded) }
            if mask & 8 != 0 { controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: succeeded) }
            if mask & 16 != 0 { controllers.beginRange(channel: channel) }
        }
        func simulateStop(succeeded: Bool) {
            reservationsEmpty = true
            transportReady = false
            for message in gates.pending { gates.record(message, succeeded: succeeded) }
            for message in controllers.pending {
                let neutral = message.status & 0xf0 == 0xe0 ? 8192 : message.data2
                controllers.record(message, neutral: neutral, succeeded: succeeded)
            }
            if succeeded {
                for channel in controllers.pendingRanges { controllers.completeRange(channel: channel) }
            }
        }
    }

    @Test(arguments: Array(0...15)) @MainActor
    func attemptedDebtSurvivesFailedFullStop(channel: Int) throws {
        for mask in 1...31 {
            for onsetSucceeded in [false, true] {
                let original = Service()
                original.seed(channel: channel, mask: mask, succeeded: onsetSucceeded)
                let replacement = Service()
                let slot = NativeHelperRelativeHostLifetime<Service>()
                let token = try #require(slot.install(original))
                let gatesBefore = original.gates.pending
                let controllersBefore = original.controllers.pending
                let rangesBefore = original.controllers.pendingRanges
                #expect(original.pending)
                original.simulateStop(succeeded: false)
                let closed = slot.close(token, retire: { $0.retireCalls += 1 }, finish: { $0.finish() })
                #expect(!closed)
                #expect(slot.phase == .closing)
                #expect(slot.activeHost(for: token) == nil)
                #expect(slot.install(replacement) == nil)
                for _ in 0..<2 {
                    original.simulateStop(succeeded: false)
                    let retry = slot.retry(token, finish: { $0.finish() })
                    #expect(!retry)
                    #expect(original.gates.pending == gatesBefore)
                    #expect(original.controllers.pending == controllersBefore)
                    #expect(original.controllers.pendingRanges == rangesBefore)
                }
                #expect(original.retireCalls == 1)
                #expect(original.finishCalls == 3)
                original.simulateStop(succeeded: true)
                #expect(!original.pending)
                let recovered = slot.retry(token, finish: { $0.finish() })
                #expect(recovered)
                let fresh = try #require(slot.install(replacement))
                let stale = slot.retry(token, finish: { $0.finish() })
                #expect(!stale)
                #expect(slot.activeHost(for: fresh) === replacement)
                #expect(replacement.finishCalls == 0)
            }
        }
    }

    @Test(arguments: Array(0...15)) @MainActor
    func liveUnrelatedObligationsAndUnknownRecovery(channel: Int) throws {
        let original = Service()
        original.seed(channel: channel, mask: 31, succeeded: true)
        original.reservationsEmpty = true
        #expect(original.pending)
        #expect(original.finish())
        original.unknownFailure = true
        #expect(!original.finish())
        original.simulateStop(succeeded: true)
        #expect(original.gates.isEmpty)
        #expect(original.controllers.isEmpty)
        #expect(original.pending)
        #expect(!original.finish())
        original.unknownFailure = false
        #expect(!original.pending)
        #expect(original.finish())
    }
}
