import Foundation

/// A logical destination, not a CoreMIDI send or delivery acknowledgement.
/// The group identity is part of the address even for equal MIDI channels.
public struct PerformanceGroupCommand: Equatable, Sendable {
    public let groupID: UUID
    public let command: SensorCommand
    public init(groupID: UUID, command: SensorCommand) {
        self.groupID = groupID
        self.command = command
    }
}

public enum PerformanceGroupRouterError: Error, Equatable {
    case invalidProfile, layeringConsentRequired, noRoute, sessionLimit, invalidTime, retired
}

/// Offline coordinator around existing SensorRouter ownership policies.
/// One logical lease per source connection, fanned out only to mapped groups.
/// No physical adapters, endpoints, timers, audio or MIDI sends are created.
public struct PerformanceGroupRouter: Sendable {
    private struct Group: Sendable {
        let sources: Set<SensorSource>
        var router: SensorRouter
    }
    private struct Lease: Sendable {
        var members: [UUID: UUID]
        var lastSeen: Double
        var sequence: UInt64?
    }
    private var groups: [UUID: Group] = [:]
    private var leases: [UUID: Lease] = [:]
    public private(set) var retired = false
    public static let maxSessions = SensorRouter.maxSessions
    public var sessionCount: Int { leases.count }
    public var groupCount: Int { groups.count }

    public init(profile: PerformanceGroupProfile, allowLayering: Bool = false) throws {
        guard profile.isValid, profile.groups.contains(where:{ !$0.patch.routes.isEmpty })
        else { throw PerformanceGroupRouterError.invalidProfile }
        guard allowLayering || profile.layeredInputs.isEmpty
        else { throw PerformanceGroupRouterError.layeringConsentRequired }
        for group in profile.groups where !group.patch.routes.isEmpty {
            var router = SensorRouter()
            try router.configure(group.patch.routes)
            groups[group.id] = Group(sources:Set(group.patch.routes.map(\.source)),router:router)
        }
    }

    /// Stage the inner connections before publishing the outer lease.
    public mutating func connect(_ source: SensorSource, now: Double) throws -> UUID {
        guard !retired else { throw PerformanceGroupRouterError.retired }
        guard now.isFinite, now >= 0 else { throw PerformanceGroupRouterError.invalidTime }
        guard leases.count < Self.maxSessions else { throw PerformanceGroupRouterError.sessionLimit }
        var next = groups
        var members: [UUID: UUID] = [:]
        for id in ordered(groups.keys) {
            guard var group = next[id], group.sources.contains(source) else { continue }
            members[id] = try group.router.connect(source,now:now)
            next[id] = group
        }
        guard !members.isEmpty else { throw PerformanceGroupRouterError.noRoute }
        let lease = UUID()
        groups = next
        leases[lease] = Lease(members:members,lastSeen:now,sequence:nil)
        return lease
    }

    /// One trusted host frame. Reject invalid or reordered frames before
    /// changing any group. Ordinary lift preserves the existing toggle policy.
    public mutating func frame(lease id: UUID, sequence: UInt64, now: Double,
                               values: [SensorSignal: Double], releasing: Set<SensorSignal> = []) -> [PerformanceGroupCommand] {
        guard !retired, var lease = leases[id], now.isFinite, now >= lease.lastSeen,
              lease.sequence.map({ sequence > $0 }) ?? true,
              values.count <= SensorSignal.allCases.count,
              values.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              releasing.isDisjoint(with:values.keys) else { return [] }
        // A release-only or empty frame also consumes sequence and renews
        // the outer lease. Use per-frame order independent of dictionary order.
        // Inner sequences need room for all possible signals, without overflow.
        let stride = UInt64(SensorSignal.allCases.count + 1)
        guard sequence <= (UInt64.max - stride) / stride else { return [] }
        let base = sequence * stride
        let signals = values.keys.sorted { $0.rawValue < $1.rawValue }
        lease.sequence = sequence
        lease.lastSeen = now
        leases[id] = lease
        var result: [PerformanceGroupCommand] = []
        for groupID in ordered(lease.members.keys) {
            guard let member = lease.members[groupID], var group = groups[groupID] else { continue }
            let events = signals.enumerated().compactMap { index, signal -> SensorEvent? in
                guard let value = values[signal] else { return nil }
                return .init(session:member,signal:signal,value:value,
                             sequence:base+UInt64(index),timestamp:now)
            }
            let raw = group.router.ingestFrame(session:member,releasing:releasing,events:events,now:now)
            // Release old notes first, establish pedal/bend/CC state, then
            // start new notes. Never depend on alphabetical destination keys.
            let commands = raw.filter { $0.destination.kind == .note && $0.value == 0 } +
                raw.filter { $0.destination.kind != .note } +
                raw.filter { $0.destination.kind == .note && $0.value > 0 }
            group.router.heartbeat(member,now:now)
            groups[groupID] = group
            result += commands.map { .init(groupID:groupID,command:$0) }
        }
        return result
    }

    public mutating func disconnect(_ id: UUID) -> [PerformanceGroupCommand] {
        disconnectBatch([id])
    }

    /// Batch expiry preserves the original reconciliation rule: never briefly
    /// restore a lower-priority control which is also being removed.
    public mutating func expire(now: Double, timeout: Double) -> [PerformanceGroupCommand] {
        guard now.isFinite, timeout.isFinite, (0.1...60).contains(timeout) else { return [] }
        let stale = Set(leases.compactMap { now - $0.value.lastSeen >= timeout ? $0.key : nil })
        return disconnectBatch(stale)
    }

    public func hasLease(_ id: UUID) -> Bool { leases[id] != nil }

    public mutating func disconnectBatch(_ ids: Set<UUID>) -> [PerformanceGroupCommand] {
        var members: [UUID: Set<UUID>] = [:]
        for id in ids {
            guard let lease = leases.removeValue(forKey:id) else { continue }
            for (group,member) in lease.members { members[group,default:[]].insert(member) }
        }
        var result: [PerformanceGroupCommand] = []
        for id in ordered(members.keys) {
            guard var group = groups[id], let departing = members[id] else { continue }
            let commands = group.router.disconnect(sessions:departing)
            groups[id] = group
            result += commands.map { .init(groupID:id,command:$0) }
        }
        return result
    }

    /// Retire only this group, leaving other bindings of the same lease alive.
    /// Reconfiguration/rearm is intentionally not supported by this candidate.
    public mutating func stopGroup(_ id: UUID) -> [PerformanceGroupCommand] {
        guard var group = groups.removeValue(forKey:id) else { return [] }
        for leaseID in Array(leases.keys) {
            guard var lease = leases[leaseID] else { continue }
            lease.members.removeValue(forKey:id)
            if lease.members.isEmpty { leases.removeValue(forKey:leaseID) }
            else { leases[leaseID] = lease }
        }
        return group.router.panic().map { .init(groupID:id,command:$0) }
    }

    public mutating func panic() -> [PerformanceGroupCommand] {
        retired = true
        var result: [PerformanceGroupCommand] = []
        for id in ordered(groups.keys) { result += stopGroup(id) }
        leases.removeAll()
        return result
    }

    private func ordered<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
        ids.sorted { $0.uuidString < $1.uuidString }
    }
}
