import Foundation

/// A saved configuration, not an active MIDI endpoint or performance lease.
/// Display names and list order never determine endpoint identity.
public struct PerformanceInstrumentGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var patch: InstrumentPatch
    public init(id: UUID = UUID(), name: String, patch: InstrumentPatch = .init()) {
        self.id = id
        self.name = name
        self.patch = patch
    }

    public var plannedPortName: String { "TIHULU Group " + id.uuidString.lowercased() }
    public var isValid: Bool {
        !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= 128 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        patch.isValid
    }
}

/// First configuration-only slice. Existing routes and their validation remain
/// authoritative. Independent ports and MPE allocation require runtime acceptance.
public struct PerformanceGroupProfile: Codable, Equatable, Sendable {
    public static let maximumGroups = 8
    public static let maximumRoutes = SensorRouter.maxMappings
    public var groups: [PerformanceInstrumentGroup]
    public init(groups: [PerformanceInstrumentGroup] = []) { self.groups = groups }

    public var isValid: Bool {
        groups.count <= Self.maximumGroups &&
        Set(groups.map(\.id)).count == groups.count &&
        groups.allSatisfy(\.isValid) &&
        groups.reduce(0) { $0 + $1.patch.routes.count } <= Self.maximumRoutes
    }

    /// Duplicate labels are permitted; duplicate identities are never permitted.
    /// Copy allocates a new identity; original mappings are unchanged.
    @discardableResult
    public mutating func add(_ group: PerformanceInstrumentGroup) -> Bool {
        var next = self
        next.groups.append(group)
        guard next.isValid else { return false }
        self = next
        return true
    }

    @discardableResult
    public mutating func duplicate(_ id: UUID, newID: UUID = UUID()) -> Bool {
        guard let original = groups.first(where:{ $0.id == id }) else { return false }
        return add(.init(id:newID,name:original.name,patch:original.patch))
    }

    /// A source assigned to several planned ports is intentional layering only
    /// after explicit runtime consent. This projection never starts any source.
    public var layeredInputs: [PatchSimulation.Input] {
        guard isValid else { return [] }
        var counts: [PatchSimulation.Input:Int] = [:]
        for group in groups {
            let inputs = Set(group.patch.routes.map { PatchSimulation.Input(source:$0.source,signal:$0.signal) })
            for input in inputs { counts[input,default:0] += 1 }
        }
        return counts.filter { $0.value > 1 }.map(\.key).sorted { $0.id < $1.id }
    }

    public func archive() throws -> Data {
        guard isValid else { throw WorkspaceArchiveError.invalidPayload }
        return try WorkspaceArchive.encode(name:"Performance groups",payload:self)
    }

    public static func read(_ data: Data) throws -> Self {
        let doc = try WorkspaceArchive.decode(Self.self,from:data)
        guard doc.payload.isValid else { throw WorkspaceArchiveError.invalidPayload }
        return doc.payload
    }
}
