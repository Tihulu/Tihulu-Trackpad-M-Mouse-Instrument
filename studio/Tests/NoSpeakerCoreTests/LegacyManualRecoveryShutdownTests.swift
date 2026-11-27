import Testing
@testable import NoSpeakerCore

struct LegacyManualRecoveryShutdownTests {
    @Test(arguments: Array(0...15))
    func sendAndNotificationAdmission(mask: Int) {
        let enabled = mask & 1 != 0
        let faulted = mask & 2 != 0
        let cleaning = mask & 4 != 0
        let unknown = mask & 8 != 0
        #expect(LegacyRecoveryPolicy.permitsSend(enabled: enabled, faulted: faulted,
            cleaning: cleaning, unknownFailure: unknown) == (cleaning || (enabled && !faulted && !unknown)))
        #expect(LegacyRecoveryPolicy.shouldNotifyManualRecovery(alreadyRequired: unknown,
            faulted: faulted, cleaning: cleaning) == (!unknown && !faulted && !cleaning))
    }

    @Test(arguments: Array(0...15))
    func manualOnlyFaultPreservesActualDebtUntilFullStop(channel: Int) {
        for failureMask in 0...63 {
            var gates = LegacyGateReleaseDebt()
            var controllers = LegacyControllerReleaseDebt()
            gates.record(.init(0x90 | channel, 60, 90), succeeded: true)
            gates.record(.init(0xb0 | channel, 64, 127), succeeded: true)
            controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: true)
            controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: true)
            controllers.beginRange(channel: channel)
            var unknown = false
            var notifications = 0
            for _ in 0..<3 {
                let notify = LegacyRecoveryPolicy.shouldNotifyManualRecovery(alreadyRequired: unknown,
                    faulted: false, cleaning: false)
                unknown = true
                if notify { notifications += 1 }
            }
            #expect(notifications == 1)
            #expect(!LegacyRecoveryPolicy.permitsSend(enabled: true, faulted: false,
                cleaning: false, unknownFailure: unknown))
            #expect(!gates.isEmpty && !controllers.isEmpty)
            var attempts = 0
            for retry in 0...1 {
                LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { gates.pending },
                    pendingRanges: { controllers.pendingRanges }, pendingControllers: { controllers.pending },
                    send: { message, neutral, range in
                        #expect(LegacyRecoveryPolicy.permitsSend(enabled: retry == 0, faulted: retry != 0,
                            cleaning: true, unknownFailure: unknown))
                        let bit: Int
                        if range { bit = message.data1 == 101 ? 16 : 32 }
                        else if LegacyGateReleaseDebt.isGate(message) { bit = message.status & 0xf0 == 0x80 ? 1 : 2 }
                        else { bit = message.status & 0xf0 == 0xe0 ? 4 : 8 }
                        attempts += 1
                        let success = retry != 0 || failureMask & bit == 0
                        gates.record(message, succeeded: success)
                        if let neutral { controllers.record(message, neutral: neutral, succeeded: success) }
                        return success
                    }, completeRange: { controllers.completeRange(channel: $0) })
                #expect(!LegacyRecoveryPolicy.permitsReplacement(gatesPending: !gates.isEmpty,
                    controllersPending: !controllers.isEmpty, unknownFailure: unknown))
                #expect(!LegacyRecoveryPolicy.shouldNotifyManualRecovery(alreadyRequired: unknown,
                    faulted: retry != 0, cleaning: true))
            }
            #expect(gates.isEmpty && controllers.isEmpty)
            #expect(attempts >= 6)
            #expect(notifications == 1)
            #expect(!LegacyRecoveryPolicy.permitsActiveStart(faulted: false, unknownFailure: unknown, cleaning: false))
        }
    }
}
