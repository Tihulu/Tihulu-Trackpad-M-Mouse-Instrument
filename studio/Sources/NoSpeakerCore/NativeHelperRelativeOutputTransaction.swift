import Foundation

/// Serialized host-side admission state for one relative helper clutch.
/// This uses the production legacy arbiter's per-target admitted commit,
/// but does not own transport cleanup or establish endpoint exclusivity.
/// The arbiter retires its relative lease before competing owner writes.
/// The host must still serialize all producers and supply real cleanup evidence.
public struct NativeHelperRelativeOutputTransaction: Sendable {
    public enum Result: Equatable, Sendable {
        case anchored, accepted, releaseRequired, blocked
    }
    private enum Phase: Sendable { case ready, active, retired }
    private let plan: NativeHelperRelativeOutputPlan
    private var phase = Phase.ready
    private var lease: UUID?
    private var expected: [SensorDestination: LegacyContinuousOwners.Value] = [:]

    public init(plan: NativeHelperRelativeOutputPlan) { self.plan = plan }

    /// Debt scope is independent of whether anchor obtained a lease.
    public var cleanupTargets: Set<SensorDestination> { plan.targetDestinations }

    /// Read-only check for the session's stationary frames and callback
    /// boundaries. This is logical ownership, not wire/receiver evidence.
    public func hasActiveLogicalLease(owners: LegacyContinuousOwners, reservedChannels: Set<Int>) -> Bool {
        guard case .active = phase, let lease, owners.permitsRelativeHelper(lease),
              expected == owners.values(for: .helper) else { return false }
        return plan.prepare(movement: [:], owners: owners, reservedChannels: reservedChannels) != nil
    }

    public mutating func anchor(owners: inout LegacyContinuousOwners, reservedChannels: Set<Int>,
                                permits: () -> Bool) -> Result {
        switch phase {
        case .active:
            if let lease { owners.invalidateRelativeHelper(lease) }
            return retire()
        case .retired: return .blocked
        case .ready: break
        }
        guard permits(), plan.permitsAnchor(owners: owners, reservedChannels: reservedChannels),
              let token = owners.reserveRelativeHelper(targets: plan.targetSet) else {
            phase = .retired
            return .blocked
        }
        lease = token; expected = [:]; phase = .active
        return .anchored
    }

    /// Only a completed admitted prefix is committed to owners. A failed
    /// wire attempt may still have reached the receiver; the host's actual
    /// attempt ledger, not this expected snapshot, owns that cleanup debt.
    public mutating func movement(_ values: [NativeHelperRelativeClutch.Axis: Int],
        owners: inout LegacyContinuousOwners, reservedChannels: Set<Int>,
        permits: () -> Bool, send: (LegacyContinuousOwners.Update) -> Bool) -> Result {
        guard case .active = phase else { return .blocked }
        guard let lease, owners.permitsRelativeHelper(lease), permits(),
              expected == owners.values(for: .helper),
              let next = plan.prepare(movement: values, owners: owners, reservedChannels: reservedChannels) else {
            if let lease { owners.invalidateRelativeHelper(lease) }
            return retire()
        }
        let accepted = owners.replaceRelativeHelperAdmitted(lease, values: next, permits: permits, send: send)
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
    public mutating func confirmCleanup(owners: inout LegacyContinuousOwners,
        genuineNeutral: Bool, transportClean: Bool) -> Bool {
        guard case .retired = phase, genuineNeutral, transportClean,
              owners.values(for: .helper).isEmpty else { return false }
        if let lease {
            owners.invalidateRelativeHelper(lease)
            guard owners.finishRelativeHelper(lease, transportClean: transportClean) else { return false }
        }
        lease = nil; expected = [:]; phase = .ready
        return true
    }
}
