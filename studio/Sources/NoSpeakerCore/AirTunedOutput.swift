import Foundation

/// Frozen logical-to-physical mapping for an isolated Air string instrument.
/// Distinct pitches retain a dedicated member throughout the run; no bend
/// stealing, no pitch-dependent voice reassignment, no hidden approximation.
public struct AirTunedOutput:Sendable {
    private let destinations:[SensorDestination:SensorDestination]
    public let members:[TunedMIDIClip.Member]
    public let setupCommands:[SensorCommand]
    public var logicalTargets:Set<SensorDestination> { Set(destinations.keys) }

    /// Only intentional zone-wide musical effects are allowed on the master.
    /// Bank, selectors, channel mode, and arbitrary custom CCs are excluded.
    private static func permits(_ route:SensorMapping) -> Bool {
        guard route.source == .camera else { return false }
        if AirStrumPerformance.isStringSignal(route.signal) { return route.destination.kind == .note }
        guard AirDualHandPerformance.helperSignals.contains(route.signal) || AirHandsHelper.allSignals.contains(route.signal) else { return false }
        switch route.destination.kind {
        case .note: return false
        case .pitchBend: return (route.response?.releaseValue(for:route.destination) ?? 8192) == 8192
        case .sustain: return true
        case .controlChange: return [1,2,7,10,11,65,66,67,69,71,74,76,77].contains(route.destination.number)
        }
    }

    public init(patch:InstrumentPatch,scale:CustomScale,root:Int) throws {
        guard patch.isValid,scale.isValid,scale.isMicrotonal,
              PhysicalPatchRuntime.supports(patch),
              AirStrumPerformance.usesStrum(patch.routes),
              patch.routes.allSatisfy(Self.permits),
              Set(patch.routes.map(\.destination.channel)).count == 1 else { throw MIDIClipError.invalidClip }
        let targets = Set(patch.routes.filter { $0.destination.kind == .note }.map(\.destination)).sorted { $0.number < $1.number }
        guard targets.count <= 15 else { throw MIDIClipError.tuningCapacity }
        var mapping:[SensorDestination:SensorDestination] = [:]
        var members:[TunedMIDIClip.Member] = []
        for (index,target) in targets.enumerated() {
            guard let pitch = scale.mpePitch(midi:target.number,root:root) else { throw MIDIClipError.invalidNote }
            mapping[target] = .init(.note,channel:index+1,number:pitch.anchor)
            members.append(.init(channel:index+1,bend:pitch.bend))
        }
        for route in patch.routes where route.destination.kind != .note {
            var master = route.destination; master.channel = 0
            mapping[route.destination] = master
        }
        destinations = mapping; self.members = members
        setupCommands = TunedMIDIClip.setup(members:members)
    }

    public func translate(_ command:SensorCommand) -> SensorCommand? {
        guard let target = destinations[command.destination],(0...(target.kind == .pitchBend ? 16383 : 127)).contains(command.value) else { return nil }
        return .init(target,value:command.value)
    }
}
