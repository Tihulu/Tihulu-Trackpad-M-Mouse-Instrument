/// Serialized host-side admission state for one relative helper clutch.
/// This uses the production legacy arbiter's per-target admitted commit,
/// but does not own transport cleanup or establish endpoint exclusivity.
/// A host must prevent competing producers from restoring a stale helper
/// value between calls and must supply real release/cleanup evidence.
public struct NativeHelperRelativeOutputTransaction: Sendable {
    public enum Result: Equatable, Sendable {
        case anchored, accepted, releaseRequired, blocked
    }
    private enum Phase: Sendable { case ready, active, retired }
    private let plan: NativeHelperRelativeOutputPlan
    private var phase = Phase.ready
    private var expected: [SensorDestination: LegacyContinuousOwners.Value] = [:]

    public init(plan: NativeHelperRelativeOutputPlan) { self.plan = plan }

    public mutating func anchor(owners: LegacyContinuousOwners, reservedChannels: Set<Int>,
                                permits: () -> Bool) -> Result {
        switch phase {
        case .active: return retire()
        case .retired: return .blocked
        case .ready: break
        }
        guard permits(), plan.permitsAnchor(owners: owners, reservedChannels: reservedChannels) else {
            phase = .retired
            return .blocked
        }
        expected = [:]; phase = .active
        return .anchored
    }

    /// Only a completed admitted prefix is committed to owners. A failed
    /// wire attempt may still have reached the receiver; the host's actual
    /// attempt ledger, not this expected snapshot, owns that cleanup debt.
    public mutating func movement(_ values: [NativeHelperRelativeClutch.Axis: Int],
        owners: inout LegacyContinuousOwners, reservedChannels: Set<Int>,
        permits: () -> Bool, send: (LegacyContinuousOwners.Update) -> Bool) -> Result {
        guard case .active = phase else { return .blocked }
        guard permits(), expected == owners.values(for: .helper),
              let next = plan.prepare(movement: values, owners: owners, reservedChannels: reservedChannels) else {
            return retire()
        }
        let accepted = owners.replaceAdmitted(.helper, values: next, permits: permits, send: send)
        expected = owners.values(for: .helper)
        guard accepted else { return retire() }
        return .accepted
    }

    /// No new movement or automatic retry after any fault or ordinary lift.
    public mutating func retire() -> Result {
        let wasActive: Bool
        if case .active = phase { wasActive = true } else { wasActive = false }
        phase = .retired
        return wasActive ? .releaseRequired : .blocked
    }

    /// Called only by the serialized host after a genuine neutral frame and
    /// its existing debt-aware cleanup. Never infer either from MIDI intent.
    @discardableResult
    public mutating func confirmCleanup(owners: LegacyContinuousOwners,
        genuineNeutral: Bool, transportClean: Bool) -> Bool {
        guard case .retired = phase, genuineNeutral, transportClean,
              owners.values(for: .helper).isEmpty else { return false }
        expected = [:]; phase = .ready
        return true
    }
}
