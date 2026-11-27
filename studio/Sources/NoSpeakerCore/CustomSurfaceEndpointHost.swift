import Foundation

/// Serialized lifecycle owner of newly created, dedicated virtual MIDI sources.
/// All callbacks are synchronous and non-reentrant. The backend must return
/// every nonzero newly created handle, even when registration fails, and must
/// never return a borrowed source. A lost identity is permanently quarantined.
public final class CustomSurfaceEndpointHost {
    public struct Endpoint: Equatable, Sendable {
        public let handle: UInt32
        public let uniqueID: Int32
        public let name: String
        public init(handle: UInt32, uniqueID: Int32, name: String) {
            self.handle = handle; self.uniqueID = uniqueID; self.name = name
        }
    }
    public struct Creation: Sendable {
        public let endpoint: Endpoint
        public let succeeded: Bool
        public init(endpoint: Endpoint, succeeded: Bool) {
            self.endpoint = endpoint; self.succeeded = succeeded
        }
    }
    public struct Backend {
        let create: (String) -> Creation?
        let owns: (Endpoint) -> Bool
        let send: (Endpoint, [UInt8]) -> Bool
        let dispose: (Endpoint) -> Bool
        public init(create: @escaping (String) -> Creation?, owns: @escaping (Endpoint) -> Bool,
                    send: @escaping (Endpoint, [UInt8]) -> Bool, dispose: @escaping (Endpoint) -> Bool) {
            self.create = create; self.owns = owns; self.send = send; self.dispose = dispose
        }
    }
    /// Aggregate local API timings, not DAW acknowledgement. Separate from
    /// Status so UI state changes need not publish every native callback.
    public struct TimingEvidence: Equatable, Sendable {
        public fileprivate(set) var identityChecks = 0
        public fileprivate(set) var failedIdentityChecks = 0
        public fileprivate(set) var sendAttempts = 0
        public fileprivate(set) var failedSends = 0
        public fileprivate(set) var maximumIdentityNS: UInt64 = 0
        public fileprivate(set) var maximumSendNS: UInt64 = 0
        public fileprivate(set) var maximumFrameAgeNS: Int64 = 0
        public var report: String {
            "Identity checks: \(identityChecks) · failed: \(failedIdentityChecks)\n" +
            "Local MIDI send attempts: \(sendAttempts) · failed: \(failedSends)\n" +
            "Max identity query: \(maximumIdentityNS / 1_000) µs\n" +
            "Max native send: \(maximumSendNS / 1_000) µs\n" +
            "Max frame age at host entry: \(maximumFrameAgeNS / 1_000) µs"
        }
        fileprivate static func increment(_ value: inout Int) {
            if value < Int.max { value += 1 }
        }
    }
    public enum Phase: Equatable, Sendable {
        case live, retired, cleanupPending, disposalPending, identityLost, closed
    }
    public struct Status: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let phase: Phase
        public let surface: CustomSurfacePadLayout.Surface
        public let outstanding: Set<SensorDestination>
        public let retirement: CustomSurfaceExclusiveDelivery.Retirement?
        public let hasNeutralHandshake: Bool
        public let activePadIDs: Set<String>
    }
    private final class Entry {
        let id: UUID
        let endpoint: Endpoint
        let surface: CustomSurfacePadLayout.Surface
        var lease: CustomSurfaceEndpointReservations.Lease?
        var phase: Phase = .live
        var report: CustomSurfaceExclusiveDelivery.Report?
        var timing = TimingEvidence()
        let clock: () -> Int64
        let measure: () -> UInt64
        init(id: UUID, endpoint: Endpoint, surface: CustomSurfacePadLayout.Surface,
             clock: @escaping () -> Int64, measure: @escaping () -> UInt64) {
            self.id = id; self.endpoint = endpoint; self.surface = surface
            self.clock = clock; self.measure = measure
        }
        var status: Status {
            .init(id: id, name: endpoint.name, phase: phase, surface: surface,
                  outstanding: report?.outstanding ?? [], retirement: report?.retirement,
                  hasNeutralHandshake: phase == .live && report?.hasNeutralHandshake == true,
                  activePadIDs: phase == .live ? (report?.activePadIDs ?? []) : [])
        }
        func validate(_ backend: Backend) -> Bool {
            guard phase != .identityLost else { return false }
            let started = measure()
            let owned = backend.owns(endpoint)
            let ended = measure()
            TimingEvidence.increment(&timing.identityChecks)
            if ended >= started { timing.maximumIdentityNS = max(timing.maximumIdentityNS, ended - started) }
            if !owned { TimingEvidence.increment(&timing.failedIdentityChecks) }
            guard owned else {
                phase = .identityLost
                return false
            }
            return true
        }
        func transmit(_ bytes: [UInt8], backend: Backend) -> Bool {
            let started = measure()
            let sent = backend.send(endpoint, bytes)
            let ended = measure()
            TimingEvidence.increment(&timing.sendAttempts)
            if !sent { TimingEvidence.increment(&timing.failedSends) }
            if ended >= started { timing.maximumSendNS = max(timing.maximumSendNS, ended - started) }
            return sent
        }
        func record(_ next: CustomSurfaceExclusiveDelivery.Report) {
            report = next
            guard phase != .identityLost else { return }
            phase = next.retired ? (next.outstanding.isEmpty ? .retired : .cleanupPending) : .live
        }
    }
    public static let capacity = 5
    private let backend: Backend
    private let measure: () -> UInt64
    private let registry = CustomSurfaceEndpointReservations()
    private var entries: [UUID: Entry] = [:]
    // Bounded final evidence, not a retained endpoint or cleanup record.
    private var lastClosedTiming: (id: UUID, evidence: TimingEvidence)?
    public init(backend: Backend, measure: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.backend = backend; self.measure = measure
    }
    public func timingEvidence(_ id: UUID) -> TimingEvidence? {
        entries[id]?.timing ?? (lastClosedTiming?.id == id ? lastClosedTiming?.evidence : nil)
    }
    public var statuses: [Status] { entries.values.map(\.status).sorted { $0.id.uuidString < $1.id.uuidString } }

    /// Returns nil only when no owned handle was created or capacity/admission
    /// refused. A nonnil recovery status is not a successful activation.
    public func open(plan: CustomSurfaceMixedPlan, permitsNeutralSilence: Bool = false, clock: @escaping () -> Int64,
                     admitsLive: @escaping () -> Bool) -> Status? {
        guard entries.count < Self.capacity, admitsLive() else { return nil }
        let id = UUID()
        let name = "TIHULU Custom Pad " + plan.layout.surface.rawValue + " " + id.uuidString
        guard let created = backend.create(name), created.endpoint.handle != 0 else { return nil }
        let endpoint = created.endpoint
        let collisions = entries.values.filter {
            $0.endpoint.handle == endpoint.handle || $0.endpoint.uniqueID == endpoint.uniqueID
        }
        // A duplicate native handle or UID undermines both incarnations.
        // Quarantine the previous record as well; neither may send or dispose
        // an ambiguous endpoint, even if a later property query succeeds.
        for collision in collisions {
            collision.phase = .identityLost
            if let lease = collision.lease, let report = registry.close(lease) {
                collision.record(report)
                if report.outstanding.isEmpty { collision.lease = nil }
            }
        }
        let entry = Entry(id: id, endpoint: endpoint, surface: plan.layout.surface, clock: clock, measure: measure)
        entries[id] = entry
        guard created.succeeded, endpoint.uniqueID != 0, endpoint.name == name, collisions.isEmpty,
              entry.validate(backend) else {
            entry.phase = .identityLost
            return entry.status
        }
        let backend = self.backend
        entry.lease = registry.open(endpointID: endpoint.uniqueID, incarnation: id,
            plan: plan, permitsNeutralSilence: permitsNeutralSilence, clock: clock, admitsLive: admitsLive,
            ownsEndpoint: { _, _ in entry.validate(backend) },
            send: { _, _, command in
                guard entry.phase != .identityLost,
                      let bytes = CustomSurfaceMIDIMessage.bytes(for: command) else { return false }
                return entry.transmit(bytes, backend: backend)
            })
        if entry.lease == nil, entry.phase != .identityLost { entry.phase = .retired }
        return entry.status
    }
    /// Wrong-source frames are rejected without renewing the watchdog or
    /// releasing another device's notes. A source adapter must not re-stamp
    /// combined cached contacts or invent empty physical snapshots.
    public func frame(_ id: UUID, surface: CustomSurfacePadLayout.Surface,
                      contacts: [CustomSurfaceContactProjection.Contact],
                      sequence: UInt64, observedAt: Int64) -> Status? {
        guard let entry = entries[id], entry.surface == surface else { return nil }
        guard entry.phase == .live else { return entry.status }
        let now = entry.clock()
        if observedAt >= 0, now >= observedAt {
            entry.timing.maximumFrameAgeNS = max(entry.timing.maximumFrameAgeNS, now - observedAt)
        }
        guard let lease = entry.lease,
              let report = registry.frame(lease, contacts: contacts, sequence: sequence, observedAt: observedAt)
        else { return entries[id]?.status }
        entry.record(report)
        return entry.status
    }
    public func poll() {
        for entry in entries.values where entry.phase == .live {
            if let lease = entry.lease, let report = registry.poll(lease) { entry.record(report) }
        }
    }
    /// A close first retires output; subsequent calls retry only retained
    /// debt or disposal. Never dispose a source whose identity is uncertain.
    @discardableResult
    public func close(_ id: UUID, retryPending: Bool = true) -> Status? {
        guard let entry = entries[id] else { return nil }
        // An automatic stop following a delivery fault must not silently
        // repeat an already failed wire cleanup or native disposal.
        if !retryPending && (entry.phase == .cleanupPending || entry.phase == .disposalPending || entry.phase == .identityLost) {
            return entry.status
        }
        if let lease = entry.lease {
            let report = entry.report?.retired == true
                ? registry.retryCleanup(lease) : registry.close(lease)
            guard let report else { return entry.status }
            entry.record(report)
            guard report.retired, report.outstanding.isEmpty else { return entry.status }
            entry.lease = nil
        }
        guard entry.validate(backend) else { return entry.status }
        guard backend.dispose(entry.endpoint) else {
            entry.phase = .disposalPending
            return entry.status
        }
        entry.phase = .closed
        lastClosedTiming = (id, entry.timing)
        entries.removeValue(forKey: id)
        return entry.status
    }
}
