import Foundation

/// Explicit, frozen per-group tuning. No profile archive changes and no
/// implicit standard-MIDI fallback. Each tuned group owns a dedicated port.
public struct PerformanceGroupTuningPlan: Sendable {
    public struct Specification: Codable, Equatable, Sendable {
        public let scale: CustomScale
        public let root: Int
        public init(scale:CustomScale,root:Int) { self.scale = scale; self.root = root }
    }
    public struct Zone: Sendable {
        public let members: [TunedMIDIClip.Member]
        public let setupCommands: [SensorCommand]
        private let targets: [SensorDestination:SensorDestination]

        fileprivate init(patch:InstrumentPatch,specification:Specification) throws {
            let scale = specification.scale, root = specification.root
            guard patch.isValid, scale.isValid, scale.isMicrotonal, (0...127).contains(root),
                  Set(patch.routes.map(\.destination.channel)).count == 1,
                  patch.routes.allSatisfy(Self.permits) else { throw MIDIClipError.invalidClip }
            let notes = Set(patch.routes.filter { $0.destination.kind == .note }.map(\.destination))
                .sorted { $0.number < $1.number }
            guard !notes.isEmpty else { throw MIDIClipError.invalidClip }
            guard notes.count <= 15 else { throw MIDIClipError.tuningCapacity }
            var map: [SensorDestination:SensorDestination] = [:]
            var allocated: [TunedMIDIClip.Member] = []
            for (index,note) in notes.enumerated() {
                let degree = (note.number-root+144)%12
                guard scale.intervals.contains(degree),
                      let pitch = scale.mpePitch(midi:note.number,root:root) else {
                    throw MIDIClipError.invalidNote
                }
                let channel = index+1
                map[note] = .init(.note,channel:channel,number:pitch.anchor)
                allocated.append(.init(channel:channel,bend:pitch.bend))
            }
            for route in patch.routes where route.destination.kind != .note {
                var master = route.destination
                master.channel = 0
                map[route.destination] = master
            }
            targets = map
            members = allocated
            setupCommands = TunedMIDIClip.setup(members:allocated)
        }

        private static func permits(_ route:SensorMapping) -> Bool {
            switch route.destination.kind {
            case .note, .sustain: return true
            case .pitchBend:
                return (route.response?.releaseValue(for:route.destination) ?? 8192) == 8192
            case .controlChange:
                return [1,2,7,10,11,65,66,67,69,71,74,76,77].contains(route.destination.number) &&
                    PerformanceGroupGamepadSession.permitsLiveControl(route)
            }
        }

        public func translate(_ command:SensorCommand) -> SensorCommand? {
            guard let target = targets[command.destination],
                  (0...(target.kind == .pitchBend ? 16383 : 127)).contains(command.value),
                  target.kind != .sustain || command.value == 0 || command.value == 127
            else { return nil }
            return .init(target,value:command.value)
        }
    }

    public let zones: [UUID:Zone]
    private let standardTargets: [UUID:Set<SensorDestination>]

    public init(profile:PerformanceGroupProfile,tuning:[UUID:Specification]) throws {
        guard profile.isValid, !tuning.isEmpty else { throw MIDIClipError.invalidClip }
        let groups = profile.groups.filter { !$0.patch.routes.isEmpty }
        guard Set(tuning.keys).isSubset(of:groups.map(\.id)) else { throw MIDIClipError.invalidClip }
        _ = try PerformanceGroupEndpointPlan(profile:profile)
        var zones: [UUID:Zone] = [:]
        var standard: [UUID:Set<SensorDestination>] = [:]
        for group in groups {
            if let spec = tuning[group.id] {
                zones[group.id] = try Zone(patch:group.patch,specification:spec)
            } else {
                guard group.patch.routes.allSatisfy(PerformanceGroupGamepadSession.permitsLiveControl)
                else { throw MIDIClipError.invalidClip }
                standard[group.id] = Set(group.patch.routes.map(\.destination))
            }
        }
        self.zones = zones
        standardTargets = standard
    }

    public var groupIDs: Set<UUID> { Set(zones.keys).union(standardTargets.keys) }

    /// Never change a note's allocated member after setup. A standard group
    /// retains its own configured logical channels on its own separate port.
    public func translate(_ item:PerformanceGroupCommand) -> PerformanceGroupCommand? {
        if let zone = zones[item.groupID] {
            guard let command = zone.translate(item.command) else { return nil }
            return .init(groupID:item.groupID,command:command)
        }
        let target = item.command.destination, value = item.command.value
        guard standardTargets[item.groupID]?.contains(target) == true,
              (0...(target.kind == .pitchBend ? 16383 : 127)).contains(value),
              target.kind != .sustain || value == 0 || value == 127 else { return nil }
        return item
    }
}
