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
    case performance = "Performance"
    case mapping = "Mapping Lab"
    case chords = "Chord Pads"
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


/// Last software boundary before constructing private actuator waveforms.
/// User-defined safety may be stricter, never looser than the default.
public enum HapticActuationAdmission: Equatable, Sendable {
    case invalid
    case silent
    case frame(HapticFrame)

    public static func prepare(_ input:HapticFrame,masterLevel:Double,
                               safety:HapticSafetyPolicy = .init()) -> Self {
        let hard = HapticSafetyPolicy()
        guard safety.maxLevel.isFinite,(0...hard.maxLevel).contains(safety.maxLevel),
              safety.minFrequencyHz.isFinite,safety.maxFrequencyHz.isFinite,
              safety.minFrequencyHz >= hard.minFrequencyHz,
              safety.maxFrequencyHz <= hard.maxFrequencyHz,
              safety.maxFrequencyHz >= safety.minFrequencyHz,
              (1...hard.maxTonesPerFrame).contains(safety.maxTonesPerFrame),
              safety.maxFrameDurationMS.isFinite,
              (0.5...hard.maxFrameDurationMS).contains(safety.maxFrameDurationMS),
              masterLevel.isFinite,(0...1).contains(masterLevel),
              input.level.isFinite,input.level >= 0,
              input.durationMS.isFinite,input.durationMS > 0 else { return .invalid }
        // Only the admitted bounded prefix can reach the actuator.
        let prefix = input.tones.prefix(safety.maxTonesPerFrame)
        guard prefix.allSatisfy({ $0.frequencyHz.isFinite && $0.frequencyHz > 0 &&
                                  $0.amplitude.isFinite && $0.amplitude >= 0 }) else { return .invalid }
        var result = safety.clamp(.init(tones:Array(prefix),durationMS:input.durationMS,level:input.level))
        result.level *= masterLevel
        result.tones.removeAll { $0.amplitude == 0 }
        guard result.level > 0,!result.tones.isEmpty else { return .silent }
        let sum = result.tones.reduce(0.0) { $0+$1.amplitude }
        guard sum.isFinite,sum > 0 else { return .invalid }
        result.tones = result.tones.map { .init(frequencyHz:$0.frequencyHz,amplitude:$0.amplitude/sum) }
        return .frame(result)
    }
}

/// Three consecutive failed submissions retire this local render session.
/// Success clears a transient streak; only an explicit new session rearms.
public struct HapticConsecutiveFailureGate: Sendable {
    public private(set) var consecutive = 0
    public private(set) var retired = false
    public init() {}
    @discardableResult
    public mutating func recordFailure() -> Bool {
        guard !retired else { return false }
        consecutive = min(3,consecutive+1)
        if consecutive == 3 { retired = true; return true }
        return false
    }
    public mutating func recordSuccess() {
        if !retired { consecutive = 0 }
    }
    public mutating func reset() { consecutive = 0; retired = false }
}
