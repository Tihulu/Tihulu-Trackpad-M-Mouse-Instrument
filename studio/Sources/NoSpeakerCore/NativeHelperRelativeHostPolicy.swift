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
}
