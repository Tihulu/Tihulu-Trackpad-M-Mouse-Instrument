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

    /// Explicit offline retarget of an existing remote mapping family to an
    /// unused slot. Preserve mapping IDs, destinations, calibration, layout
    /// labels and the group's port identity. Never overwrite another slot.
    @discardableResult
    public mutating func reassignRemoteSource(groupID:UUID,from:SensorSource,to:SensorSource) -> Bool {
        guard isValid,from.isGroupRemote,to.isGroupRemote,from != to,
              let index = groups.firstIndex(where:{ $0.id == groupID }),
              !groups.contains(where:{ $0.patch.routes.contains(where:{ $0.source == to }) }) else { return false }
        let moved = groups[index].patch.routes.filter { $0.source == from }
        guard !moved.isEmpty else { return false }
        var next = self
        for routeIndex in next.groups[index].patch.routes.indices where next.groups[index].patch.routes[routeIndex].source == from {
            next.groups[index].patch.routes[routeIndex].source = to
        }
        if var layout = next.groups[index].patch.performanceLayout {
            for widgetIndex in layout.widgets.indices where layout.widgets[widgetIndex].source == from {
                layout.widgets[widgetIndex].source = to
            }
            next.groups[index].patch.performanceLayout = layout
        }
        let targetRoutes = next.groups[index].patch.routes.filter { $0.source == to }
        guard next.isValid,PerformanceGroupRemoteSurface.modes(for:targetRoutes) != nil else { return false }
        self = next
        return true
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


/// Local, named copies of editable group layouts. Independent of the active
/// profile, physical devices, tuning consent and runtime state.
public struct PerformanceGroupPresetLibrary:Codable,Equatable,Sendable {
    public static let maximumEntries=16
    public struct Entry:Codable,Equatable,Identifiable,Sendable {
        public let id:UUID
        public let name:String
        public let profile:PerformanceGroupProfile
        public init(id:UUID=UUID(),name:String,profile:PerformanceGroupProfile) {
            self.id=id;self.name=name;self.profile=profile
        }
        fileprivate var isValid:Bool {
            name == name.trimmingCharacters(in:.whitespacesAndNewlines) &&
            !name.isEmpty && name.utf8.count<=128 &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            profile.isValid && !profile.groups.isEmpty
        }
    }
    public private(set) var entries:[Entry]=[]
    public init() {}
    public var isValid:Bool {
        entries.count<=Self.maximumEntries &&
        Set(entries.map(\.id)).count==entries.count &&
        Set(entries.map { $0.name.lowercased() }).count==entries.count &&
        entries.allSatisfy(\.isValid)
    }
    public func archive() throws -> Data {
        guard isValid else { throw WorkspaceArchiveError.invalidPayload }
        return try WorkspaceArchive.encode(name:"Group preset library",payload:self)
    }
    public static func read(_ data:Data) throws -> Self {
        let decoded=try WorkspaceArchive.decode(Self.self,from:data).payload
        guard decoded.isValid else { throw WorkspaceArchiveError.invalidPayload }
        return decoded
    }
    /// Never overwrite a same-name entry. Validate both count and encoded
    /// size before committing so every successful addition is persistable.
    @discardableResult
    public mutating func add(name:String,profile:PerformanceGroupProfile,id:UUID=UUID()) -> Bool {
        var next=self
        next.entries.append(.init(id:id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),profile:profile))
        guard (try? next.archive()) != nil else { return false }
        self=next
        return true
    }
    /// Explicit replacement of an exact reviewed entry. Stale selections
    /// cannot overwrite a newer revision. Keep the library entry identity.
    @discardableResult
    public mutating func update(expected:Entry,name:String,profile:PerformanceGroupProfile) -> Bool {
        guard let index=entries.firstIndex(of:expected) else { return false }
        var next=self
        next.entries[index] = .init(id:expected.id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),profile:profile)
        guard (try? next.archive()) != nil else { return false }
        self=next
        return true
    }
    @discardableResult
    public mutating func remove(_ id:UUID) -> Bool {
        guard isValid,entries.contains(where:{ $0.id==id }) else { return false }
        entries.removeAll { $0.id==id }
        return true
    }
}


/// Session-only group draft. Retain unfinished names and mappings, but
/// never restore a draft over a changed saved archive (even equal content).
public struct PerformanceGroupDraftSession:Sendable {
    private struct Pending:Sendable {
        let draft:PerformanceGroupProfile
        let saved:PerformanceGroupProfile
        let archive:Data?
    }
    private var pending:Pending?
    public init() {}
    public mutating func remember(_ draft:PerformanceGroupProfile,saved:PerformanceGroupProfile,archive:Data?) {
        pending=draft==saved ? nil : .init(draft:draft,saved:saved,archive:archive)
    }
    public mutating func resume(saved:PerformanceGroupProfile,archive:Data?) -> PerformanceGroupProfile {
        guard let pending,pending.saved==saved,pending.archive==archive else {
            clear()
            return saved
        }
        return pending.draft
    }
    public mutating func clear() { pending=nil }
}
