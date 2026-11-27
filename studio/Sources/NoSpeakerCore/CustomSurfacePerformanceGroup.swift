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
    private var clock: (() -> Int64)?
    private var startedAt: Int64?
    private var lastClock: Int64?
    public static let neutralTimeoutNS: Int64 = 10_000_000_000
    private var ids: [Surface: UUID] = [:]
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
        let gate = Admission(admitsLive)
        admission = gate
        for member in members {
            guard let status = host.open(plan: member.plan, permitsNeutralSilence: member.permitsNeutralSilence,
                                         clock: clock, admitsLive: { gate.check() }) else {
                stop()
                return phase == .idle ? .rolledBack : .recoveryPending
            }
            ids[member.plan.layout.surface] = status.id
            guard status.phase == .live, gate.check() else {
                stop()
                return phase == .idle ? .rolledBack : .recoveryPending
            }
        }
        guard statuses.count == members.count, statuses.allSatisfy({ $0.phase == .live }), gate.check() else {
            stop()
            return phase == .idle ? .rolledBack : .recoveryPending
        }
        let now = clock()
        guard now >= 0 else { stop(); return phase == .idle ? .rolledBack : .recoveryPending }
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
        guard healthy() else { stop(); return nil }
        let result = host.frame(id, surface: surface, contacts: contacts, sequence: sequence, observedAt: observedAt)
        if result?.phase != .live || !healthy() { stop(); return nil }
        return result
    }
    public func poll(run: UUID) {
        guard runID == run else { return }
        guard healthy() else { stop(); return }
        host.poll()
        if !healthy() { stop() }
    }
    private func healthy() -> Bool {
        guard admission?.check() == true, let clock, let startedAt, let lastClock else { return false }
        let now = clock()
        guard now >= lastClock else { return false }
        self.lastClock = now
        let current = statuses
        return current.count == ids.count && current.allSatisfy { $0.phase == .live } &&
            (current.allSatisfy { $0.hasNeutralHandshake } || now - startedAt < Self.neutralTimeoutNS) &&
            admission?.check() == true
    }
    /// Retire admission before any cleanup. Automatic stop must not retry
    /// an already failed cleanup; recovery requires a distinct explicit call.
    public func stop() {
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
                ids.removeValue(forKey: surface)
            }
        }
    }
}
