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
    public enum Phase: Equatable, Sendable {
        case live, retired, cleanupPending, disposalPending, identityLost, closed
    }
    public struct Status: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let phase: Phase
        public let outstanding: Set<SensorDestination>
        public let retirement: CustomSurfaceExclusiveDelivery.Retirement?
    }
    private final class Entry {
        let id: UUID
        let endpoint: Endpoint
        var lease: CustomSurfaceEndpointReservations.Lease?
        var phase: Phase = .live
        var report: CustomSurfaceExclusiveDelivery.Report?
        init(id: UUID, endpoint: Endpoint) { self.id = id; self.endpoint = endpoint }
        var status: Status {
            .init(id: id, name: endpoint.name, phase: phase,
                  outstanding: report?.outstanding ?? [], retirement: report?.retirement)
        }
        func validate(_ backend: Backend) -> Bool {
            guard phase != .identityLost, backend.owns(endpoint) else {
                phase = .identityLost
                return false
            }
            return true
        }
        func record(_ next: CustomSurfaceExclusiveDelivery.Report) {
            report = next
            guard phase != .identityLost else { return }
            phase = next.retired ? (next.outstanding.isEmpty ? .retired : .cleanupPending) : .live
        }
    }
    public static let capacity = 5
    private let backend: Backend
    private let registry = CustomSurfaceEndpointReservations()
    private var entries: [UUID: Entry] = [:]
    public init(backend: Backend) { self.backend = backend }
    public var statuses: [Status] { entries.values.map(\.status).sorted { $0.id.uuidString < $1.id.uuidString } }

    /// Returns nil only when no owned handle was created or capacity/admission
    /// refused. A nonnil recovery status is not a successful activation.
    public func open(plan: CustomSurfaceMixedPlan, clock: @escaping () -> Int64,
                     admitsLive: @escaping () -> Bool) -> Status? {
        guard entries.count < Self.capacity, admitsLive() else { return nil }
        let id = UUID()
        let name = "TIHULU Custom Pad " + plan.layout.surface.rawValue + " " + id.uuidString
        guard let created = backend.create(name), created.endpoint.handle != 0 else { return nil }
        let endpoint = created.endpoint
        let duplicate = entries.values.contains {
            $0.endpoint.handle == endpoint.handle || $0.endpoint.uniqueID == endpoint.uniqueID
        }
        let entry = Entry(id: id, endpoint: endpoint)
        entries[id] = entry
        guard created.succeeded, endpoint.uniqueID != 0, endpoint.name == name, !duplicate,
              entry.validate(backend) else {
            entry.phase = .identityLost
            return entry.status
        }
        let backend = self.backend
        entry.lease = registry.open(endpointID: endpoint.uniqueID, incarnation: id,
            plan: plan, clock: clock, admitsLive: admitsLive,
            ownsEndpoint: { _, _ in entry.validate(backend) },
            send: { _, _, command in
                guard entry.phase != .identityLost,
                      let bytes = CustomSurfaceMIDIMessage.bytes(for: command) else { return false }
                return backend.send(endpoint, bytes)
            })
        if entry.lease == nil, entry.phase != .identityLost { entry.phase = .retired }
        return entry.status
    }
    public func frame(_ id: UUID, contacts: [CustomSurfaceContactProjection.Contact],
                      sequence: UInt64, observedAt: Int64) -> Status? {
        guard let entry = entries[id], entry.phase == .live, let lease = entry.lease,
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
    public func close(_ id: UUID) -> Status? {
        guard let entry = entries[id] else { return nil }
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
        entries.removeValue(forKey: id)
        return entry.status
    }
}
