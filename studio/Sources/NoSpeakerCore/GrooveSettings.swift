import Foundation

/// Optional, repeatable sixteenth-note groove for the existing grid editors.
/// Does not mutate the source pattern or generate a new random take each loop.
public struct GrooveSettings: Codable, Equatable, Sendable {
    public var swing = 50
    public var humanize = 0
    public var intensity = 100
    public var accent = 0
    public var probability = 100
    public var seed = 1
    public init() {}

    public var isValid: Bool {
        (50...75).contains(swing) && (0...100).contains(humanize) &&
        (25...125).contains(intensity) && (0...30).contains(accent) &&
        (25...100).contains(probability) && (1...9999).contains(seed)
    }

    public func apply(to input: MIDIClip) throws -> MIDIClip {
        let clip = try input.validated()
        let step = MIDIClip.ppq / 4
        guard isValid, clip.notes.allSatisfy({ $0.start % step == 0 && $0.duration <= step })
        else { throw MIDIClipError.invalidClip }
        // Canonical ordering makes random draws independent of source ordering.
        var state = UInt64(seed)
        func draw(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upper))
        }
        let delay = step * (swing - 50) / 50
        let jitter = humanize * 24 / 100
        let velocityJitter = humanize * 12 / 100
        var transformed: [MIDIClip.Note] = []
        for original in clip.notes {
            let index = original.start / step
            // Preserve one downbeat if present; probability applies to all
            // other hits. An all-rest result is explicitly rejected.
            let chance = draw(100)
            let timingVariation = draw(2 * jitter + 1) - jitter
            let velocityVariation = draw(2 * velocityJitter + 1) - velocityJitter
            guard original.start == 0 || chance < probability else { continue }
            var n = original
            let offset = index % 2 == 1 ? delay : 0
            n.start = min(clip.length - 1, max(0, original.start + offset + timingVariation))
            n.duration = min(n.duration, clip.length - n.start)
            let boost = index % 4 == 0 ? accent : 0
            n.velocity = min(127, max(1, Int((Double(n.velocity) * Double(intensity) / 100).rounded()) + boost + velocityVariation))
            transformed.append(n)
        }
        // Keep each identical pitch/channel's Note Off before its next Note
        // On, even when swing shifts one onset closer to the next.
        var nextOnset: [Int:Int] = [:]
        for i in transformed.indices.reversed() {
            let key = transformed[i].channel * 128 + transformed[i].pitch
            if let next = nextOnset[key] {
                transformed[i].duration = min(transformed[i].duration, next - transformed[i].start)
            }
            nextOnset[key] = transformed[i].start
        }
        return try MIDIClip(bpm: clip.bpm, length: clip.length, notes: transformed).validated()
    }
}

public extension MIDIClip {
    /// Existing haptic voice profiles, with the same groove onsets and
    /// velocity as export. Drum motor timbre is not a MIDI synthesizer.
    func grooveHapticEvents() throws -> [ScheduledHapticEvent] {
        let clip = try validated()
        let secondsPerTick = 60 / clip.bpm / Double(Self.ppq)
        return try clip.notes.map { note in
            let level = Double(note.velocity) / 127
            var frame: HapticFrame
            if note.channel == 9, let voice = MIDIDrumMap.voice(for: note.pitch) {
                frame = HapticPatternRenderer.drumFrame(voice, velocity: level)
            } else {
                frame = .init(tones: [.init(frequencyHz: try MusicTheory.frequency(midi: note.pitch))],
                              durationMS: Double(note.duration) * secondsPerTick * 1000, level: level)
            }
            frame.durationMS = min(frame.durationMS, Double(clip.length - note.start) * secondsPerTick * 1000)
            return .init(time: Double(note.start) * secondsPerTick, frame: frame)
        }
    }
}
