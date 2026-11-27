import Testing
@testable import NoSpeakerCore

struct NativeHelperRelativeEmptyClosureTests {
    @Test func emptyClosureTruthTable() {
        for reservationsEmpty in [false, true] {
            for transportReady in [false, true] {
                for cleanupPending in [false, true] {
                    for recoveryRequired in [false, true] {
                        let expected: Bool
                        if !reservationsEmpty || recoveryRequired { expected = false }
                        else if transportReady { expected = true }
                        else { expected = !cleanupPending }
                        #expect(NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(
                            reservationsEmpty: reservationsEmpty, transportReady: transportReady,
                            shutdownCleanupPending: cleanupPending, recoveryRequired: recoveryRequired) == expected)
                    }
                }
            }
        }
    }

    @MainActor private final class Service {
        var reservationsEmpty = false
        var transportReady = true
        var cleanupPending = true
        var recoveryRequired = false
        var retireCount = 0
        var finishCount = 0

        func finish() -> Bool {
            finishCount += 1
            return NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(
                reservationsEmpty: reservationsEmpty, transportReady: transportReady,
                shutdownCleanupPending: cleanupPending, recoveryRequired: recoveryRequired)
        }
    }

    @Test @MainActor func fullStopDebtRetainsOriginalOwner() throws {
        for unknownFailure in [false, true] {
            let slot = NativeHelperRelativeHostLifetime<Service>()
            let original = Service()
            let replacement = Service()
            let token = try #require(slot.install(original))
            // Simulate whole-source Stop clearing logical owners before wire cleanup.
            original.reservationsEmpty = true
            original.transportReady = false
            original.recoveryRequired = unknownFailure
            let clean = slot.close(token, retire: { $0.retireCount += 1 }, finish: { $0.finish() })
            #expect(!clean)
            #expect(slot.phase == .closing)
            #expect(slot.activeHost(for: token) == nil)
            #expect(slot.install(replacement) == nil)
            for _ in 0..<3 {
                let retried = slot.retry(token, finish: { $0.finish() })
                #expect(!retried)
            }
            #expect(original.retireCount == 1)
            #expect(original.finishCount == 4)
            #expect(replacement.finishCount == 0)
            original.cleanupPending = false
            if unknownFailure {
                let retried = slot.retry(token, finish: { $0.finish() })
                #expect(!retried)
            }
            original.recoveryRequired = false
            let recovered = slot.retry(token, finish: { $0.finish() })
            #expect(recovered)
            let newToken = try #require(slot.install(replacement))
            let staleRetry = slot.retry(token, finish: { $0.finish() })
            #expect(!staleRetry)
            #expect(slot.activeHost(for: newToken) === replacement)
            #expect(replacement.finishCount == 0)
        }
    }

    @Test @MainActor func liveScopedCloseDoesNotBlockOtherOwners() throws {
        let slot = NativeHelperRelativeHostLifetime<Service>()
        let original = Service()
        let token = try #require(slot.install(original))
        original.reservationsEmpty = true
        // A live unrelated instrument may retain ordinary note/CC debt.
        let clean = slot.close(token, retire: { $0.retireCount += 1 }, finish: { $0.finish() })
        #expect(clean)
        #expect(slot.phase == .idle)
        #expect(original.cleanupPending)
        #expect(original.retireCount == 1)
    }
}
