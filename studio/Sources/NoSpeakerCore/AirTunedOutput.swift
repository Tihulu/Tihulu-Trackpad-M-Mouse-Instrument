import Foundation

/// Frozen logical-to-physical mapping for an isolated Air string instrument.
/// Distinct pitches retain a dedicated member throughout the run; no bend
/// stealing, no pitch-dependent voice reassignment, no hidden approximation.
public struct AirTunedOutput:Sendable {
    private let destinations:[SensorDestination:SensorDestination]
    public let members:[TunedMIDIClip.Member]
    public var setupCommands:[SensorCommand] { TunedMIDIClip.setup(members:members) }

    public init(patch:InstrumentPatch,scale:CustomScale,root:Int) throws {
        guard patch.isValid,scale.isValid,scale.isMicrotonal,
              PhysicalPatchRuntime.supports(patch),
              AirStrumPerformance.usesStrum(patch.routes),
              patch.routes.allSatisfy({ $0.source == .camera && AirStrumPerformance.isStringSignal($0.signal) && $0.destination.kind == .note }),
              Set(patch.routes.map(\.destination.channel)).count == 1 else { throw MIDIClipError.invalidClip }
        let targets = Set(patch.routes.map(\.destination)).sorted { $0.number < $1.number }
        guard targets.count <= 15 else { throw MIDIClipError.tuningCapacity }
        var mapping:[SensorDestination:SensorDestination] = [:]
        var members:[TunedMIDIClip.Member] = []
        for (index,target) in targets.enumerated() {
            guard let pitch = scale.mpePitch(midi:target.number,root:root) else { throw MIDIClipError.invalidNote }
            mapping[target] = .init(.note,channel:index+1,number:pitch.anchor)
            members.append(.init(channel:index+1,bend:pitch.bend))
        }
        destinations = mapping; self.members = members
    }

    public func translate(_ command:SensorCommand) -> SensorCommand? {
        guard let target = destinations[command.destination],(0...127).contains(command.value) else { return nil }
        return .init(target,value:command.value)
    }
}
