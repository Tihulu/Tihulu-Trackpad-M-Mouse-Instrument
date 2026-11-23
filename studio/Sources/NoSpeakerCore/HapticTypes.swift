import Foundation

public struct HapticTone: Sendable, Equatable, Codable {
    public var frequencyHz: Double
    public var amplitude: Double

    public init(frequencyHz: Double, amplitude: Double = 1.0) {
        self.frequencyHz = frequencyHz
        self.amplitude = amplitude
    }
}

public struct HapticFrame: Sendable, Equatable, Codable {
    public var tones: [HapticTone]
    public var durationMS: Double
    public var level: Double

    public init(tones: [HapticTone], durationMS: Double, level: Double) {
        self.tones = tones
        self.durationMS = durationMS
        self.level = level
    }
}

public struct HapticSafetyPolicy: Sendable, Equatable, Codable {
    public var maxLevel: Double
    public var minFrequencyHz: Double
    public var maxFrequencyHz: Double
    public var maxTonesPerFrame: Int
    public var maxFrameDurationMS: Double

    public init(
        maxLevel: Double = 1.0,
        minFrequencyHz: Double = 98.0,
        maxFrequencyHz: Double = 3_951.0,
        maxTonesPerFrame: Int = 6,
        maxFrameDurationMS: Double = 120.0
    ) {
        self.maxLevel = maxLevel
        self.minFrequencyHz = minFrequencyHz
        self.maxFrequencyHz = maxFrequencyHz
        self.maxTonesPerFrame = maxTonesPerFrame
        self.maxFrameDurationMS = maxFrameDurationMS
    }

    public func clamp(_ frame: HapticFrame) -> HapticFrame {
        let safeTones = frame.tones.prefix(max(1, maxTonesPerFrame)).map {
            HapticTone(
                frequencyHz: min(max($0.frequencyHz, minFrequencyHz), maxFrequencyHz),
                amplitude: min(max($0.amplitude, 0), 1)
            )
        }
        return HapticFrame(
            tones: Array(safeTones),
            durationMS: min(max(frame.durationMS, 0.5), maxFrameDurationMS),
            level: min(max(frame.level, 0), maxLevel)
        )
    }
}

public enum StudioMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case voice = "Voice"
    case touch = "Touch Instrument"
    case notes = "Note Sequencer"
    case drums = "Drum Sequencer"
    case midiHelper = "MIDI Helper"
    case touchBar = "Touch Bar & Tilt"
    case midi = "MIDI / Logic"
    case audio = "Audio File"
    case speaker = "Trackpad Speaker"
    case diagnostics = "Diagnostics"
    case about = "About"

    public var id: String { rawValue }
}

public struct ScheduledHapticEvent: Sendable, Equatable, Codable {
    public var time: Double
    public var frame: HapticFrame

    public init(time: Double, frame: HapticFrame) {
        self.time = time
        self.frame = frame
    }
}

public enum AudioHapticProfile: String, CaseIterable, Identifiable, Sendable, Codable {
    case melody = "Melody"
    case rhythm = "Rhythm"
    case voice = "Voice"
    case fullMix = "Full Mix"

    public var id: String { rawValue }
}
