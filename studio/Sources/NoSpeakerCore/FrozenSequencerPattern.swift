import Foundation

/// Immutable nominal take prepared entirely offline. This is a grid contract,
/// not a live session, endpoint reservation or permission to start playback.
/// The host must retain its own scheduler, cancellation and cleanup gates.
public struct FrozenSequencerPattern: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case notes, drums }
    public enum ValidationError: Error, Equatable {
        case invalidGrid, invalidStep, duplicateStep, invalidGroove
    }

    public let kind: Kind
    public let stepCount: Int
    public let stepsPerBeat: Int
    public let loop: Bool
    public let clip: MIDIClip

    public init(notes: NoteSequence, channel: Int = 0, loop: Bool = false,
                groove: GrooveSettings? = nil) throws {
        try Self.validate(notes: notes, channel: channel, groove: groove)
        kind = .notes
        stepCount = notes.length
        stepsPerBeat = notes.stepsPerBeat
        self.loop = loop
        clip = try Self.prepare(MIDIClip.melody(notes, channel: channel),
                                stepsPerBeat: stepsPerBeat, groove: groove)
    }

    public init(drums: DrumSequence, loop: Bool = false, groove: GrooveSettings? = nil) throws {
        try Self.validate(drums: drums, groove: groove)
        kind = .drums
        stepCount = drums.length
        stepsPerBeat = drums.stepsPerBeat
        self.loop = loop
        clip = try Self.prepare(MIDIClip.drums(drums), stepsPerBeat: stepsPerBeat, groove: groove)
    }

    // Draft validation is also used by the offline archive. Empty and muted
    // drafts are valid editor data, but MIDIClip still rejects empty playback.
    static func validate(notes: NoteSequence, channel: Int, groove: GrooveSettings?) throws {
        try validateGrid(bpm: notes.bpm, stepsPerBeat: notes.stepsPerBeat, length: notes.length)
        guard notes.steps.count <= notes.length, (0...15).contains(channel) else {
            throw ValidationError.invalidGrid
        }
        var occupied = Set<Int>()
        for step in notes.steps {
            guard (0..<notes.length).contains(step.index),
                  step.velocity.isFinite, (0...1).contains(step.velocity),
                  step.gate.isFinite, (0.05...1).contains(step.gate),
                  step.midi.map({ (0...127).contains($0) }) ?? true else {
                throw ValidationError.invalidStep
            }
            guard occupied.insert(step.index).inserted else {
                throw ValidationError.duplicateStep
            }
        }
        try validateGroove(groove, stepsPerBeat: notes.stepsPerBeat)
    }

    static func validate(drums: DrumSequence, groove: GrooveSettings?) throws {
        try validateGrid(bpm: drums.bpm, stepsPerBeat: drums.stepsPerBeat, length: drums.length)
        guard drums.hits.count <= min(16_384, drums.length * DrumVoice.allCases.count) else {
            throw ValidationError.invalidGrid
        }
        var occupied: [DrumVoice: Set<Int>] = [:]
        for hit in drums.hits {
            guard (0..<drums.length).contains(hit.index),
                  hit.velocity.isFinite, (0...1).contains(hit.velocity) else {
                throw ValidationError.invalidStep
            }
            guard occupied[hit.voice, default: []].insert(hit.index).inserted else {
                throw ValidationError.duplicateStep
            }
        }
        try validateGroove(groove, stepsPerBeat: drums.stepsPerBeat)
    }

    private static func validateGroove(_ groove: GrooveSettings?, stepsPerBeat: Int) throws {
        if let groove, stepsPerBeat != 4 || !groove.isValid { throw ValidationError.invalidGroove }
    }

    private static func validateGrid(bpm: Double, stepsPerBeat: Int, length: Int) throws {
        guard bpm.isFinite, (20...300).contains(bpm),
              (1...MIDIClip.ppq).contains(stepsPerBeat),
              MIDIClip.ppq % stepsPerBeat == 0, (1...4096).contains(length),
              length <= (MIDIClip.ppq * 4 * 256) / (MIDIClip.ppq / stepsPerBeat) else {
            throw ValidationError.invalidGrid
        }
    }

    private static func prepare(_ clip: MIDIClip, stepsPerBeat: Int,
                                groove: GrooveSettings?) throws -> MIDIClip {
        guard let groove else { return clip }
        guard stepsPerBeat == 4, groove.isValid else { throw ValidationError.invalidGroove }
        return try groove.apply(to: clip)
    }

    /// Includes trailing rests. The existing validated schedule is the
    /// sole source of event order and note-off deadlines.
    public func schedule() throws -> MIDIClipSchedule { try MIDIClipSchedule(clip) }

    public var duration: Double { Double(clip.length) * 60 / clip.bpm / Double(MIDIClip.ppq) }

    /// Project a scheduler-confirmed tick within the current cycle onto
    /// the grid. No wall clock or extrapolation, and no automatic wrap.
    /// This identifies the transport subdivision, not a sounding voice.
    public func gridStep(atConfirmedTick tick: Int) -> Int? {
        guard (0..<clip.length).contains(tick) else { return nil }
        return tick / (MIDIClip.ppq / stepsPerBeat)
    }
}
