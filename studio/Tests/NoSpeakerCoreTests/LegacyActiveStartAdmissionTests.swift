import Testing
@testable import NoSpeakerCore

struct LegacyActiveStartAdmissionTests {
    @Test(arguments: Array(0...7))
    func activeStartRequiresHealthyTransport(mask: Int) {
        let faulted = mask & 1 != 0
        let unknown = mask & 2 != 0
        let cleaning = mask & 4 != 0
        let expected = !faulted && !unknown && !cleaning
        #expect(LegacyRecoveryPolicy.permitsActiveStart(faulted: faulted,
            unknownFailure: unknown, cleaning: cleaning) == expected)
    }

    @Test(arguments: Array(0...15))
    func activeReuseDoesNotConfuseLiveDebtWithShutdownDebt(channel: Int) {
        var gates = LegacyGateReleaseDebt()
        var controllers = LegacyControllerReleaseDebt()
        gates.record(.init(0x90 | channel, 60, 90), succeeded: true)
        controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: true)
        #expect(!LegacyRecoveryPolicy.permitsReplacement(gatesPending: !gates.isEmpty,
            controllersPending: !controllers.isEmpty, unknownFailure: false))
        #expect(LegacyRecoveryPolicy.permitsActiveStart(faulted: false, unknownFailure: false, cleaning: false))
        #expect(!LegacyRecoveryPolicy.permitsActiveStart(faulted: true, unknownFailure: false, cleaning: false))
        #expect(!LegacyRecoveryPolicy.permitsActiveStart(faulted: false, unknownFailure: true, cleaning: false))
        #expect(!LegacyRecoveryPolicy.permitsActiveStart(faulted: false, unknownFailure: false, cleaning: true))
        // Emergency sends remain available during explicit cleanup, not via active start.
        #expect(LegacyRecoveryPolicy.permitsSend(enabled: false, faulted: true, cleaning: true))
        #expect(!LegacyRecoveryPolicy.permitsSend(enabled: true, faulted: true, cleaning: false))
    }
}
