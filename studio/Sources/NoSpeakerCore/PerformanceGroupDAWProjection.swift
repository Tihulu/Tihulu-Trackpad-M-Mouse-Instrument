import Foundation

/// Offline DAW wiring preview. Every displayed channel is one-based and
/// comes from the actual translation plan, not the logical mapping channel.
/// A preview never registers a port, sends MIDI, or certifies a receiver.
public struct PerformanceGroupDAWProjection: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case standard, lowerMPE
    }

    public struct Route: Equatable, Sendable {
        public let mappingID: String
        public let source: SensorSource
        public let signal: SensorSignal
        public let logical: SensorDestination
        public let wire: SensorDestination
        public var channel: Int { wire.channel + 1 }
    }

    public struct Member: Equatable, Sendable {
        public let channel: Int
        public let bend: Int
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let port: String
        public let mode: Mode
        public let routes: [Route]
        public let members: [Member]
        public var masterChannel: Int? { mode == .lowerMPE ? 1 : nil }
        public var channels: [Int] { Array(Set(routes.map(\.channel))).sorted() }
    }

    public let groups: [Group]

    /// A supplied but stale/invalid tuning document throws; it must never
    /// silently become a standard-MIDI projection.
    public init(profile: PerformanceGroupProfile,
                configuration: PerformanceGroupTuningConfiguration? = nil) throws {
        guard profile.isValid else { throw MIDIClipError.invalidClip }
        _ = try PerformanceGroupEndpointPlan(profile:profile)
        let plan = try configuration?.plan(matching:profile)
        groups = try profile.groups.filter { !$0.patch.routes.isEmpty }.map { group in
            let zone = plan?.zones[group.id]
            let routes = try group.patch.routes.map { mapping -> Route in
                let logical = mapping.destination
                let wire: SensorDestination
                if let plan {
                    let probe = PerformanceGroupCommand(groupID:group.id,
                        command:.init(logical,value:0))
                    guard let translated = plan.translate(probe) else {
                        throw MIDIClipError.invalidClip
                    }
                    wire = translated.command.destination
                } else {
                    wire = logical
                }
                return Route(mappingID:mapping.id,source:mapping.source,
                             signal:mapping.signal,logical:logical,wire:wire)
            }
            let members = (zone?.members ?? []).map {
                Member(channel:$0.channel + 1,bend:$0.bend)
            }
            return Group(id:group.id,name:group.name,port:group.plannedPortName,
                         mode:zone == nil ? .standard : .lowerMPE,
                         routes:routes,members:members)
        }
    }
}
