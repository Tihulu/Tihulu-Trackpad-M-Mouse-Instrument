import Foundation

/// Stable candidate identity for a virtual CoreMIDI source. The full UUID
/// remains authoritative; the 31-bit system ID can collide. Never resolve a
/// collision by silently choosing a new ID or taking over another endpoint.
public struct PerformanceGroupEndpointPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let portName: String
        public let uniqueID: Int32
    }
    public let entries: [Entry]

    public init(profile: PerformanceGroupProfile) throws {
        guard profile.isValid else { throw PerformanceGroupRouterError.invalidProfile }
        let entries = profile.groups.filter { !$0.patch.routes.isEmpty }.map {
            Entry(id:$0.id,portName:$0.plannedPortName,uniqueID:Self.uniqueID($0.id))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !entries.isEmpty else { throw PerformanceGroupRouterError.invalidProfile }
        guard Set(entries.map(\.uniqueID)).count == entries.count else {
            throw EndpointError.identityCollision
        }
        self.entries = entries
    }

    public enum EndpointError: Error, Equatable {
        case identityCollision
    }

    /// Versioned namespace and deterministic FNV-1a, independent of Swift's
    /// per-process randomized Hashable seed. Positive, nonzero Int32 only.
    public static func uniqueID(_ id: UUID) -> Int32 {
        let bytes = ("TIHULU.group.v1:" + id.uuidString.lowercased()).utf8
        var hash: UInt32 = 2166136261
        for byte in bytes { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return Int32((hash & 0x7fffffff) == 0 ? 1 : (hash & 0x7fffffff))
    }

    /// A host checks the system registry again at creation time. This check
    /// alone cannot guarantee the ID is still free when registration occurs.
    public func permitsRegistration(occupied: Set<Int32>) -> Bool {
        entries.allSatisfy { !occupied.contains($0.uniqueID) }
    }
}
