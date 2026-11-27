import Testing
@testable import NoSpeakerCore

private func replacementPlan(_ channel: Int) -> NativeHelperRelativeOutputPlan {
    NativeHelperRelativeOutputPlan(targets: [.x: .init(.pitchBend, channel: channel),
        .y: .init(.controlChange, channel: channel, number: 74)])!
}

@Test(arguments: Array(0..<16))
func relativeReplacementNeutralSeparatesOldCleanupFromCurrentPlan(channel: Int) {
    let old = replacementPlan((channel + 1) % 16), next = replacementPlan(channel)
    for anchored in [false, true] {
        for debtKind in 0..<3 {
            for scope in 0..<3 {
                var owners = LegacyContinuousOwners(), debt = LegacyControllerReleaseDebt()
                var transaction = NativeHelperRelativeOutputTransaction(plan: old)
                let onset = transaction.anchor(owners: &owners, reservedChannels: [], permits: { anchored })
                #expect(onset == (anchored ? .anchored : .blocked))
                _ = transaction.retire()
                let dirtyChannel = [channel, (channel + 1) % 16, (channel + 2) % 16][scope]
                switch debtKind {
                case 0: debt.record(.init(0xb0 | dirtyChannel, 74, 90), neutral: 0, succeeded: false)
                case 1: debt.record(.init(0xe0 | dirtyChannel, 1, 70), neutral: 8192, succeeded: false)
                default: debt.beginRange(channel: dirtyChannel)
                }
                let reserved = owners.relativeReservedTargets
                let result = NativeHelperRelativeHostPolicy.finishRetirement(transaction: &transaction,
                    owners: &owners, reservedTargets: reserved, genuineNeutral: true,
                    currentPlanTargets: next.targetDestinations, debt: debt, transportReady: true, recoveryRequired: false)
                #expect(result.finished == (scope != 1))
                #expect(result.neutralPermitted == (scope == 2))
                #expect(owners.relativeReservedTargets == (scope == 1 ? reserved : []))
                #expect(!debt.isEmpty)
            }
        }
    }
}

@Test func relativeReplacementNeutralRequiresCurrentPlanAndGenuineCleanBoundary() {
    let plan = replacementPlan(2)
    for mode in 0..<6 {
        var owners = LegacyContinuousOwners()
        var transaction = NativeHelperRelativeOutputTransaction(plan: plan)
        let anchored = transaction.anchor(owners: &owners, reservedChannels: [], permits: { true })
        #expect(anchored == .anchored)
        _ = transaction.retire()
        let reserved = owners.relativeReservedTargets
        let current: Set<SensorDestination>? = mode == 0 ? nil : mode == 1 ? [] : plan.targetDestinations
        let result = NativeHelperRelativeHostPolicy.finishRetirement(transaction: &transaction,
            owners: &owners, reservedTargets: reserved, genuineNeutral: mode != 2,
            currentPlanTargets: current, debt: .init(), transportReady: mode != 3, recoveryRequired: mode == 4)
        #expect(result.finished == (mode < 2 || mode == 5))
        #expect(result.neutralPermitted == (mode == 5))
        #expect(owners.relativeReservedTargets.isEmpty == result.finished)
    }
}
