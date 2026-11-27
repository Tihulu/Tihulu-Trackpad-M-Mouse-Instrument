import Foundation

/// Serialized, explicit group of isolated Custom Pad sources. This portable
/// coordinator does not register physical devices or grant input permission.
/// The caller exclusively owns the host for the group's lifetime and supplies
/// complete source-specific snapshots from independent physical adapters.
public final class CustomSurfacePerformanceGroup {
    public typealias Surface = CustomSurfacePadLayout.Surface
    public typealias Status = CustomSurfaceEndpointHost.Status
    public struct Member {
        public let plan: CustomSurfaceMixedPlan
        public let permitsNeutralSilence: Bool
        public init(plan: CustomSurfaceMixedPlan, permitsNeutralSilence: Bool = false) {
            self.plan = plan; self.permitsNeutralSilence = permitsNeutralSilence
        }
    }
    public enum Phase: Equatable, Sendable { case idle, live, recoveryPending }
    public enum StartResult: Equatable, Sendable {
        case started(UUID), refused, rolledBack, recoveryPending
    }
    private final class Admission {
        var open = true
        let external: () -> Bool
        init(_ external: @escaping () -> Bool) { self.external = external }
        func check() -> Bool {
            guard open else { return false }
            if !external() { open = false }
            return open
        }
    }
    private let host: CustomSurfaceEndpointHost
    private var admission: Admission?
    public enum StopReason: Equatable, Sendable {
        case requested, admissionLost, clockInvalid, neutralTimeout, portCreation, memberUnavailable(Surface), memberFault(Surface, CustomSurfaceExclusiveDelivery.Retirement?), identityLost(Surface)
    }
    public private(set) var stopReason: StopReason?
    private var clock: (() -> Int64)?
    private var startedAt: Int64?
    private var lastClock: Int64?
    public static let neutralTimeoutNS: Int64 = 10_000_000_000
    private var ids: [Surface: UUID] = [:]
    private var closedEvidence: [Surface: CustomSurfaceEndpointHost.TimingEvidence] = [:]
    public var timingEvidence: [Surface: CustomSurfaceEndpointHost.TimingEvidence] {
        var result = closedEvidence
        for (surface,id) in ids { result[surface] = host.timingEvidence(id) }
        return result
    }
    public private(set) var runID: UUID?
    public init(host: CustomSurfaceEndpointHost) { self.host = host }
    deinit { admission?.open = false }
    public var statuses: [Status] {
        host.statuses.filter { ids.values.contains($0.id) }
    }
    public var phase: Phase {
        if runID != nil { return .live }
        return ids.isEmpty ? .idle : .recoveryPending
    }

    /// Preflight the complete group before opening any port. No frames are
    /// admitted through this API until all endpoints have opened successfully.
    /// Independent ports require independent receiver routing; merging them
    /// downstream is outside this coordinator's ownership guarantees.
    public func start(_ members: [Member], clock: @escaping () -> Int64,
                      admitsLive: @escaping () -> Bool) -> StartResult {
        let surfaces = members.map { $0.plan.layout.surface }
        guard phase == .idle, host.statuses.isEmpty, !members.isEmpty,
              members.count <= CustomSurfaceEndpointHost.capacity,
              Set(surfaces).count == members.count, admitsLive() else { return .refused }
        closedEvidence.removeAll()
        stopReason = nil
        let gate = Admission(admitsLive)
        admission = gate
        for member in members {
            guard let status = host.open(plan: member.plan, permitsNeutralSilence: member.permitsNeutralSilence,
                                         clock: clock, admitsLive: { gate.check() }) else {
                retire(.portCreation)
                return phase == .idle ? .rolledBack : .recoveryPending
            }
            ids[member.plan.layout.surface] = status.id
            guard status.phase == .live, gate.check() else {
                retire(status.phase == .live ? .admissionLost : reason(for: status))
                return phase == .idle ? .rolledBack : .recoveryPending
            }
        }
        guard statuses.count == members.count, statuses.allSatisfy({ $0.phase == .live }), gate.check() else {
            retire(.admissionLost)
            return phase == .idle ? .rolledBack : .recoveryPending
        }
        let now = clock()
        guard now >= 0, gate.check() else { retire(now < 0 ? .clockInvalid : .admissionLost); return phase == .idle ? .rolledBack : .recoveryPending }
        self.clock = clock
        startedAt = now
        lastClock = now
        let token = UUID()
        runID = token
        return .started(token)
    }

    /// Wrong generation or unconfigured source cannot renew any member.
    /// A member fault retires the entire group, not a silent partial rearm.
    @discardableResult
    public func frame(run: UUID, surface: Surface, contacts: [CustomSurfaceContactProjection.Contact],
                      sequence: UInt64, observedAt: Int64) -> Status? {
        guard runID == run, let id = ids[surface] else { return nil }
        if let fault = healthFault() { retire(fault); return nil }
        let result = host.frame(id, surface: surface, contacts: contacts, sequence: sequence, observedAt: observedAt)
        guard let result else { retire(.memberUnavailable(surface)); return nil }
        guard result.phase == .live else { retire(reason(for: result)); return nil }
        if let fault = healthFault() { retire(fault); return nil }
        return result
    }
    public func poll(run: UUID) {
        guard runID == run else { return }
        if let fault = healthFault() { retire(fault); return }
        host.poll()
        if let fault = healthFault() { retire(fault) }
    }
    private func reason(for status: Status) -> StopReason {
        status.phase == .identityLost ? .identityLost(status.surface) : .memberFault(status.surface, status.retirement)
    }
    private func healthFault() -> StopReason? {
        let current = statuses
        for surface in Surface.allCases where ids[surface] != nil {
            guard let status = current.first(where: { $0.surface == surface }) else { return .memberUnavailable(surface) }
            if status.phase != .live { return reason(for: status) }
        }
        guard admission?.check() == true else { return .admissionLost }
        guard let clock, let startedAt, let lastClock else { return .clockInvalid }
        let now = clock()
        guard now >= lastClock else { return .clockInvalid }
        self.lastClock = now
        guard current.allSatisfy({ $0.hasNeutralHandshake }) || now - startedAt < Self.neutralTimeoutNS else { return .neutralTimeout }
        return admission?.check() == true ? nil : .admissionLost
    }
    /// Retire admission before any cleanup. Automatic stop must not retry
    /// an already failed cleanup; recovery requires a distinct explicit call.
    public func stop() { retire(.requested) }
    private func retire(_ reason: StopReason) {
        if stopReason == nil, runID != nil || admission != nil { stopReason = reason }
        admission?.open = false
        admission = nil
        runID = nil
        clock = nil; startedAt = nil; lastClock = nil
        closeOwned(retry: false)
    }
    public func retryRecovery() {
        guard runID == nil else { return }
        closeOwned(retry: true)
    }
    private func closeOwned(retry: Bool) {
        // Stable order makes fault injection and trace comparison reproducible.
        for surface in Surface.allCases {
            guard let id = ids[surface] else { continue }
            if host.close(id, retryPending: retry)?.phase == .closed {
                // Copy before closing the next source overwrites the host's
                // single most-recently-closed timing slot.
                closedEvidence[surface] = host.timingEvidence(id)
                ids.removeValue(forKey: surface)
            }
        }
    }
}
