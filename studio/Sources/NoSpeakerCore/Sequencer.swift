import Foundation

public struct NoteStep: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var index: Int
    public var midi: Int?
    public var velocity: Double
    public var gate: Double

    public init(id: UUID = UUID(), index: Int, midi: Int? = nil, velocity: Double = 0.85, gate: Double = 0.8) {
        self.id = id
        self.index = index
        self.midi = midi
        self.velocity = velocity
        self.gate = gate
    }
}

public enum DrumVoice: String, CaseIterable, Sendable, Codable, Hashable {
    case kick, snare, closedHat, openHat, clap, tom
}

public struct DrumStep: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var index: Int
    public var voice: DrumVoice
    public var velocity: Double

    public init(id: UUID = UUID(), index: Int, voice: DrumVoice, velocity: Double = 0.9) {
        self.id = id
        self.index = index
        self.voice = voice
        self.velocity = velocity
    }
}

public struct NoteSequence: Sendable, Equatable {
    public var bpm: Double
    public var stepsPerBeat: Int
    public var length: Int
    public var steps: [NoteStep]

    public init(bpm: Double = 120, stepsPerBeat: Int = 4, length: Int = 16, steps: [NoteStep] = []) {
        self.bpm = bpm
        self.stepsPerBeat = stepsPerBeat
        self.length = length
        self.steps = steps
    }

    public var stepDuration: Double { 60.0 / bpm / Double(stepsPerBeat) }
}

public struct DrumSequence: Sendable, Equatable {
    public var bpm: Double
    public var stepsPerBeat: Int
    public var length: Int
    public var hits: [DrumStep]

    public init(bpm: Double = 120, stepsPerBeat: Int = 4, length: Int = 16, hits: [DrumStep] = []) {
        self.bpm = bpm
        self.stepsPerBeat = stepsPerBeat
        self.length = length
        self.hits = hits
    }

    public var stepDuration: Double { 60.0 / bpm / Double(stepsPerBeat) }
}

public enum HapticPatternRenderer {
    public static func notes(_ sequence: NoteSequence) throws -> [ScheduledHapticEvent] {
        try sequence.steps.compactMap { step in
            guard let midi = step.midi, step.index >= 0, step.index < sequence.length else { return nil }
            let frequency = try MusicTheory.frequency(midi: midi)
            let duration = sequence.stepDuration * min(max(step.gate, 0.05), 1.0)
            return ScheduledHapticEvent(
                time: Double(step.index) * sequence.stepDuration,
                frame: HapticFrame(
                    tones: [HapticTone(frequencyHz: frequency)],
                    durationMS: duration * 1_000,
                    level: min(max(step.velocity, 0), 1)
                )
            )
        }.sorted { $0.time < $1.time }
    }

    public static func drums(_ sequence: DrumSequence) -> [ScheduledHapticEvent] {
        sequence.hits.compactMap { hit in
            guard hit.index >= 0, hit.index < sequence.length else { return nil }
            return ScheduledHapticEvent(
                time: Double(hit.index) * sequence.stepDuration,
                frame: drumFrame(hit.voice, velocity: hit.velocity)
            )
        }.sorted { $0.time < $1.time }
    }

    public static func drumFrame(_ voice: DrumVoice, velocity: Double) -> HapticFrame {
        let level = min(max(velocity, 0), 1)
        switch voice {
        case .kick:
            return HapticFrame(tones: [HapticTone(frequencyHz: 120)], durationMS: 70, level: level)
        case .snare:
            return HapticFrame(
                tones: [HapticTone(frequencyHz: 1_700, amplitude: 0.6), HapticTone(frequencyHz: 2_800, amplitude: 0.4)],
                durationMS: 42,
                level: level
            )
        case .closedHat:
            return HapticFrame(tones: [HapticTone(frequencyHz: 3_700)], durationMS: 18, level: level * 0.75)
        case .openHat:
            return HapticFrame(tones: [HapticTone(frequencyHz: 3_500)], durationMS: 65, level: level * 0.75)
        case .clap:
            return HapticFrame(
                tones: [HapticTone(frequencyHz: 1_900), HapticTone(frequencyHz: 3_100)],
                durationMS: 32,
                level: level * 0.8
            )
        case .tom:
            return HapticFrame(tones: [HapticTone(frequencyHz: 220)], durationMS: 80, level: level)
        }
    }
}

public enum MIDIDrumMap {
    public static func voice(for note: Int) -> DrumVoice? {
        switch note {
        case 35, 36: return .kick
        case 38, 40: return .snare
        case 42, 44: return .closedHat
        case 46: return .openHat
        case 39: return .clap
        case 41, 43, 45, 47, 48, 50: return .tom
        default: return nil
        }
    }
}
