/// Shared policy for a serialized legacy CoreMIDI host. Reserved channels
/// stay excluded from MPE allocation until the lease is actually finished.
public enum NativeHelperRelativeHostPolicy {
    public static func reservedChannels(targets: Set<SensorDestination>) -> Set<Int> {
        Set(targets.map(\.channel))
    }

    /// Direct CC writes bypass the owner arbiter. Never admit an overlapping
    /// target or a channel-wide routing/range/reset operation while leased.
    /// Ordinary sustain CC64 remains independent.
    public static func conflictsWithDirectCC(channel: Int, controller: Int,
                                             targets: Set<SensorDestination>) -> Bool {
        guard targets.contains(where: { $0.channel == channel }) else { return false }
        if [0,6,32,38,96,97,98,99,100,101].contains(controller) || (120...127).contains(controller) { return true }
        return targets.contains(.init(.controlChange, channel: channel, number: controller))
    }

    /// Active notes and unrelated controller debt do not prevent a scoped
    /// clutch. Pending neutral/range on the same target must not be ignored.
    /// Transport faults/unknown state are separately checked by the host.
    public static func hasPendingCleanup(targets: Set<SensorDestination>,
                                         debt: LegacyControllerReleaseDebt) -> Bool {
        let channels = reservedChannels(targets: targets)
        if !channels.isDisjoint(with: debt.pendingRanges) { return true }
        return debt.pending.contains { message in
            let channel = message.status & 15
            switch message.status & 0xf0 {
            case 0xb0: return targets.contains(.init(.controlChange, channel: channel, number: message.data1))
            case 0xe0: return targets.contains(.init(.pitchBend, channel: channel))
            default: return false
            }
        }
    }

    /// Cleanliness is scoped to the immutable plan even if anchor failed
    /// before obtaining a reservation. Never use this union as send targets.
    public static func permitsCleanupConfirmation(plannedTargets: Set<SensorDestination>,
        reservedTargets: Set<SensorDestination>, debt: LegacyControllerReleaseDebt,
        transportReady: Bool, recoveryRequired: Bool) -> Bool {
        !plannedTargets.isEmpty && transportReady && !recoveryRequired &&
            !hasPendingCleanup(targets: plannedTargets.union(reservedTargets), debt: debt)
    }

    /// Before a transaction exists, only an explicit, genuinely neutral
    /// observation for a known plan may authorize a future anchor. No sends.
    public static func permitsInitialNeutral(genuineNeutral: Bool, plannedTargets: Set<SensorDestination>?,
        owners: LegacyContinuousOwners, debt: LegacyControllerReleaseDebt,
        transportReady: Bool, recoveryRequired: Bool) -> Bool {
        guard genuineNeutral, let plannedTargets, owners.relativeReservedTargets.isEmpty,
              owners.values(for: .helper).isEmpty else { return false }
        return permitsCleanupConfirmation(plannedTargets: plannedTargets, reservedTargets: [], debt: debt,
            transportReady: transportReady, recoveryRequired: recoveryRequired)
    }

    /// Completing a retired transaction and admitting the current plan are
    /// different results. The old lease may be disposed even if the new
    /// configuration must wait for another genuinely clean neutral frame.
    public struct RetirementResult: Equatable, Sendable {
        public let finished: Bool
        public let neutralPermitted: Bool
    }

    /// Call after releasing only the old reserved helper intent. The
    /// reservedTargets snapshot is for cleanliness, never for new sends.
    /// Missing current-plan evidence never authorizes a new neutral.
    public static func finishRetirement(transaction: inout NativeHelperRelativeOutputTransaction,
        owners: inout LegacyContinuousOwners, reservedTargets: Set<SensorDestination>,
        genuineNeutral: Bool, currentPlanTargets: Set<SensorDestination>?,
        debt: LegacyControllerReleaseDebt, transportReady: Bool, recoveryRequired: Bool) -> RetirementResult {
        let clean = permitsCleanupConfirmation(plannedTargets: transaction.cleanupTargets,
            reservedTargets: reservedTargets, debt: debt, transportReady: transportReady,
            recoveryRequired: recoveryRequired)
        let finished = transaction.confirmCleanup(owners: &owners, genuineNeutral: genuineNeutral, transportClean: clean)
        let neutralPermitted = finished && permitsInitialNeutral(genuineNeutral: genuineNeutral,
            plannedTargets: currentPlanTargets, owners: owners, debt: debt,
            transportReady: transportReady, recoveryRequired: recoveryRequired)
        return .init(finished: finished, neutralPermitted: neutralPermitted)
    }
}
