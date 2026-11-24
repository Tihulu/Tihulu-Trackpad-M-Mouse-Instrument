import Foundation

public enum MIDIClipError: LocalizedError, Equatable {
    case invalidClip, invalidNote, overlappingNote, empty
    public var errorDescription: String? {
        switch self {
        case .invalidClip: "Invalid tempo, timing or clip length."
        case .invalidNote: "Invalid MIDI note, channel, velocity or duration."
        case .overlappingNote: "Overlapping identical notes on one MIDI channel are not supported."
        case .empty: "Add at least one note or drum hit before exporting."
        }
    }
}

/// Model-neutral symbolic clip. Tick units are fixed at 960 PPQ.
/// No executable content, tempo automation, SysEx or implicit pitch bend.
public struct MIDIClip: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        public var start: Int
        public var duration: Int
        public var channel: Int // zero-based
        public var pitch: Int
        public var velocity: Int
        public init(start: Int, duration: Int, channel: Int, pitch: Int, velocity: Int) {
            self.start = start
            self.duration = duration
            self.channel = channel
            self.pitch = pitch
            self.velocity = velocity
        }
    }
    public static let ppq = 960
    public var bpm: Double
    public var length: Int
    public var notes: [Note]

    public init(bpm: Double, length: Int, notes: [Note]) {
        self.bpm = bpm
        self.length = length
        self.notes = notes
    }

    public func validated() throws -> MIDIClip {
        guard bpm.isFinite, (20...300).contains(bpm),
              (1...Self.ppq * 4 * 256).contains(length),
              notes.count <= 16_384 else { throw MIDIClipError.invalidClip }
        guard !notes.isEmpty else { throw MIDIClipError.empty }
        for n in notes {
            guard (0..<length).contains(n.start), n.duration > 0,
                  n.duration <= length - n.start,
                  (0...15).contains(n.channel), (0...127).contains(n.pitch),
                  (1...127).contains(n.velocity) else { throw MIDIClipError.invalidNote }
        }
        let sorted = notes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.pitch < $1.pitch
        }
        var ends: [Int: Int] = [:]
        for n in sorted {
            let key = n.channel * 128 + n.pitch
            guard n.start >= (ends[key] ?? 0) else { throw MIDIClipError.overlappingNote }
            ends[key] = n.start + n.duration
        }
        return .init(bpm: bpm, length: length, notes: sorted)
    }

    private static func timing(bpm: Double, steps: Int, length: Int) throws -> (Int, Int) {
        guard bpm.isFinite, (20...300).contains(bpm), (1...ppq).contains(steps),
              ppq % steps == 0, (1...4096).contains(length) else { throw MIDIClipError.invalidClip }
        let step = ppq / steps
        return (step, step * length)
    }

    private static func velocity(_ value: Double) throws -> Int {
        guard value.isFinite, (0...1).contains(value) else { throw MIDIClipError.invalidNote }
        return max(1, Int((value * 127).rounded()))
    }

    public static func melody(_ sequence: NoteSequence, channel: Int = 0) throws -> MIDIClip {
        let (step, length) = try timing(bpm: sequence.bpm, steps: sequence.stepsPerBeat, length: sequence.length)
        guard sequence.steps.count <= 4096 else { throw MIDIClipError.invalidClip }
        var notes: [Note] = []
        for n in sequence.steps {
            guard let pitch = n.midi else { continue }
            guard (0..<sequence.length).contains(n.index), n.gate.isFinite,
                  (0.05...1).contains(n.gate) else { throw MIDIClipError.invalidNote }
            let v = try velocity(n.velocity)
            if n.velocity == 0 { continue }
            notes.append(.init(start: n.index * step, duration: max(1, Int((Double(step) * n.gate).rounded())),
                               channel: channel, pitch: pitch, velocity: v))
        }
        return try MIDIClip(bpm: sequence.bpm, length: length, notes: notes).validated()
    }

    public static func drums(_ sequence: DrumSequence) throws -> MIDIClip {
        let (step, length) = try timing(bpm: sequence.bpm, steps: sequence.stepsPerBeat, length: sequence.length)
        guard sequence.hits.count <= 16_384 else { throw MIDIClipError.invalidClip }
        let pitches: [DrumVoice:Int] = [.kick:36,.snare:38,.closedHat:42,.openHat:46,.clap:39,.tom:47]
        var notes: [Note] = []
        for hit in sequence.hits {
            guard (0..<sequence.length).contains(hit.index), let pitch = pitches[hit.voice] else { throw MIDIClipError.invalidNote }
            let v = try velocity(hit.velocity)
            if hit.velocity == 0 { continue }
            notes.append(.init(start: hit.index * step, duration: max(1, step / 2),
                               channel: 9, pitch: pitch, velocity: v))
        }
        return try MIDIClip(bpm: sequence.bpm, length: length, notes: notes).validated()
    }

    /// Exports nominal pitches only. The UI must explicitly identify that
    /// this does not preserve microtonal offsets or MPE routing.
    public static func progression(_ progression: ChordProgression, bank: ChordBank, bpm: Double) throws -> MIDIClip {
        guard let plan = progression.plan(bank: bank, bpm: bpm) else { throw MIDIClipError.invalidClip }
        let ticksPerSecond = bpm / 60 * Double(ppq)
        let length = Int((plan.duration * ticksPerSecond).rounded())
        let notes = plan.steps.flatMap { step -> [Note] in
            guard let pad = step.pad else { return [] }
            let start = Int((step.onset * ticksPerSecond).rounded())
            let end = Int(((step.onset + step.gate) * ticksPerSecond).rounded())
            return pad.notes.map { .init(start: start, duration: max(1, end - start),
                                         channel: plan.channel, pitch: $0, velocity: plan.velocity) }
        }
        return try MIDIClip(bpm: bpm, length: length, notes: notes).validated()
    }
}

public enum MIDIClipWriter {
    /// Standard MIDI File format 0, with explicit note-offs and End of Track
    /// at the full clip boundary, including trailing rests.
    public static func encode(_ input: MIDIClip) throws -> Data {
        let clip = try input.validated()
        struct Event {
            let tick: Int
            let off: Bool
            let channel: Int
            let pitch: Int
            let velocity: Int
        }
        let events = clip.notes.flatMap { n in
            [Event(tick: n.start, off: false, channel: n.channel, pitch: n.pitch, velocity: n.velocity),
             Event(tick: n.start + n.duration, off: true, channel: n.channel, pitch: n.pitch, velocity: 0)]
        }.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.off != $1.off { return $0.off }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.pitch < $1.pitch
        }
        func be(_ value: Int, count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
        }
        func vlq(_ value: Int) -> [UInt8] {
            var n = value
            var bytes = [UInt8(n & 127)]
            n >>= 7
            while n > 0 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
            return Array(bytes.reversed())
        }
        var track: [UInt8] = [0,0xFF,0x51,3]
        track += be(Int((60_000_000 / clip.bpm).rounded()), count: 3)
        var previous = 0
        for e in events {
            track += vlq(e.tick - previous)
            track += [UInt8((e.off ? 0x80 : 0x90) | e.channel), UInt8(e.pitch), UInt8(e.velocity)]
            previous = e.tick
        }
        track += vlq(clip.length - previous)
        track += [0xFF,0x2F,0]
        var file = Array("MThd".utf8) + be(6,count:4) + be(0,count:2) + be(1,count:2) + be(MIDIClip.ppq,count:2)
        file += Array("MTrk".utf8) + be(track.count,count:4) + track
        return Data(file)
    }
}
