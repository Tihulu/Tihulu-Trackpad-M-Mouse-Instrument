import Foundation

/// Offline, single-instrument MPE export. Each member is permanently
/// assigned one bend for the whole clip, so later notes cannot retune an
/// earlier release tail. Overlapping notes still get distinct members.
public struct TunedMIDIClip: Sendable {
    public struct Member: Equatable, Sendable {
        public let channel:Int
        public let bend:Int
    }
    public let clip:MIDIClip
    public let members:[Member]

    public init(_ input:MIDIClip,scale:CustomScale,root:Int) throws {
        let source = try input.validated()
        guard scale.isValid,(0...127).contains(root),
              Set(source.notes.map(\.channel)).count == 1 else { throw MIDIClipError.invalidClip }
        var allocated:[Member] = []
        var endByChannel:[Int:Int] = [:]
        var notes:[MIDIClip.Note] = []
        for note in source.notes {
            guard let pitch = scale.mpePitch(midi:note.pitch,root:root) else { throw MIDIClipError.invalidNote }
            let member:Member
            if let reuse = allocated.first(where:{ $0.bend == pitch.bend && (endByChannel[$0.channel] ?? 0) <= note.start }) {
                member = reuse
            } else {
                guard allocated.count < 15 else { throw MIDIClipError.tuningCapacity }
                member = .init(channel:allocated.count+1,bend:pitch.bend)
                allocated.append(member)
            }
            endByChannel[member.channel] = note.start+note.duration
            var copy = note; copy.channel = member.channel
            notes.append(copy)
        }
        clip = try MIDIClip(bpm:source.bpm,length:source.length,notes:notes).validated()
        members = allocated
    }

    /// Identical setup for offline export and the isolated live port.
    public var setupCommands:[SensorCommand] { Self.setup(members:members) }

    static func setup(members:[Member]) -> [SensorCommand] {
        var commands:[SensorCommand] = []
        func cc(_ channel:Int,_ number:Int,_ value:Int) {
            commands.append(.init(.init(.controlChange,channel:channel,number:number),value:value))
        }
        func rpn(_ channel:Int,_ number:Int,_ value:Int,fine:Bool = false) {
            cc(channel,101,0); cc(channel,100,number); cc(channel,6,value)
            if fine { cc(channel,38,0) }
            cc(channel,101,127); cc(channel,100,127)
        }
        // Explicit lower zone, no upper zone. Dedicated receiving instrument.
        rpn(15,6,0)
        rpn(0,6,members.count)
        rpn(0,0,2,fine:true)
        commands.append(.init(.init(.pitchBend),value:8192))
        for member in members {
            rpn(member.channel,0,2,fine:true)
            commands.append(.init(.init(.pitchBend,channel:member.channel),value:member.bend))
        }
        return commands
    }

    static func wireBytes(_ command:SensorCommand) -> [UInt8] {
        let d = command.destination, v = command.value
        switch d.kind {
        case .pitchBend: return [UInt8(0xe0|d.channel),UInt8(v & 127),UInt8(v >> 7)]
        case .note: return [UInt8((v == 0 ? 0x80 : 0x90)|d.channel),UInt8(d.number),UInt8(v)]
        case .sustain: return [UInt8(0xb0|d.channel),64,UInt8(v)]
        case .controlChange: return [UInt8(0xb0|d.channel),UInt8(d.number),UInt8(v)]
        }
    }

    public func encoded() -> Data {
        var events:[(Int,[UInt8])] = setupCommands.map { (0,Self.wireBytes($0)) }
        struct Gate {
            let tick:Int
            let channel:Int
            let pitch:Int
            let velocity:Int
        }
        let gates = clip.notes.flatMap { n in [
            Gate(tick:n.start,channel:n.channel,pitch:n.pitch,velocity:n.velocity),
            Gate(tick:n.start+n.duration,channel:n.channel,pitch:n.pitch,velocity:0)
        ] }.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if ($0.velocity == 0) != ($1.velocity == 0) { return $0.velocity == 0 }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.pitch < $1.pitch
        }
        events += gates.map { ($0.tick,[UInt8(($0.velocity == 0 ? 0x80 : 0x90)|$0.channel),UInt8($0.pitch),UInt8($0.velocity)]) }
        return MIDIClipWriter.encodeEvents(bpm:clip.bpm,length:clip.length,events:events)
    }
}
