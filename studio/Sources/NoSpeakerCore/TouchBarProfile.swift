import Foundation

/// User-chosen zones for a native or on-screen Touch Bar performance surface.
public enum TouchBarZone: String, CaseIterable, Codable, Identifiable, Sendable {
    case keys = "Piano Keys"
    case chords = "Chord Pads"
    case fretless = "Fretless Glide"
    case pitchBend = "Pitch Bend"
    case vibrato = "Vibrato"
    case expression = "Expression"
    case sustain = "Sustain"
    case filter = "Filter Cutoff"
    case wah = "Wah (CC4)"

    public var id: String { rawValue }

    /// Bend and fretless ribbons are momentary; other CCs are latched.
    public var releasePosition: Double? {
        switch self { case .pitchBend,.fretless: 0.5; default: nil }
    }
    public var initialPosition: Double {
        switch self { case .pitchBend,.fretless: 0.5; case .expression: 1; default: 0 }
    }
}

public enum TouchBarSustainMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case hold = "Hold"
    case toggle = "Toggle"
    public var id: String { rawValue }
}

public enum TiltMIDITarget: String, CaseIterable, Codable, Identifiable, Sendable {
    case disabled = "Disabled"
    case filter = "CC74 Filter"
    case wah = "CC4 Wah"
    case expression = "CC11 Expression"
    case vibrato = "CC1 Vibrato"
    case pitchBend = "Pitch Bend"
    public var id: String { rawValue }
}

public struct TouchBarProfile: Codable, Equatable, Sendable {
    public var zones: [TouchBarZone]
    public var sustainMode: TouchBarSustainMode
    /// Zero-based CoreMIDI channel: 0 means DAW Channel 1.
    public var channel: Int
    public var baseNote: Int
    public var noteVelocity: Int
    public var tiltTarget: TiltMIDITarget
    public var tiltMinDegrees: Double
    public var tiltMaxDegrees: Double
    public var musicalOutput: MusicalOutput?
    public var effectiveOutput: MusicalOutput { musicalOutput ?? .midi }

    public init(
        zones: [TouchBarZone] = [.keys, .pitchBend, .vibrato, .sustain],
        sustainMode: TouchBarSustainMode = .hold,
        channel: Int = 0,
        baseNote: Int = 60,
        noteVelocity: Int = 100,
        tiltTarget: TiltMIDITarget = .disabled,
        tiltMinDegrees: Double = 50,
        tiltMaxDegrees: Double = 135
    ) {
        self.zones = zones
        self.sustainMode = sustainMode
        self.channel = channel
        self.baseNote = baseNote
        self.noteVelocity = noteVelocity
        self.tiltTarget = tiltTarget
        self.tiltMinDegrees = tiltMinDegrees
        self.tiltMaxDegrees = tiltMaxDegrees
    }

    public func normalized() -> TouchBarProfile {
        var copy = self
        var unique = Set<TouchBarZone>()
        copy.zones = zones.filter { unique.insert($0).inserted }
        if copy.zones.isEmpty { copy.zones = [.keys] }
        copy.channel = max(0, min(15, channel))
        copy.baseNote = max(0, min(115, baseNote))
        copy.noteVelocity = max(1, min(127, noteVelocity))
        copy.tiltMinDegrees = tiltMinDegrees.isFinite ? min(170,max(5,tiltMinDegrees)) : 90
        copy.tiltMaxDegrees = min(175,max(copy.tiltMinDegrees+5,tiltMaxDegrees.isFinite ? tiltMaxDegrees : 120))
        return copy
    }

    /// Neutral values follow the same convention as the MIDI release ledger.
    /// The calibrated angle is for the simulator display, not a new live sample.
    public var neutralTilt: (zone: TouchBarZone, value: Double, angle: Double)? {
        let zone: TouchBarZone
        let value: Double
        switch tiltTarget {
        case .disabled: return nil
        case .filter: zone = .filter; value = 0
        case .wah: zone = .wah; value = 0
        case .vibrato: zone = .vibrato; value = 0
        case .expression: zone = .expression; value = 1
        case .pitchBend: zone = .pitchBend; value = 0.5
        }
        let config = normalized()
        let angle = config.tiltMinDegrees + value * (config.tiltMaxDegrees - config.tiltMinDegrees)
        return (zone, value, angle)
    }

    public func normalizedTilt(_ degrees: Double) -> Double? {
        let config = normalized()
        guard degrees.isFinite, config.tiltTarget != .disabled else { return nil }
        return min(1, max(0,
            (degrees - config.tiltMinDegrees) /
            (config.tiltMaxDegrees - config.tiltMinDegrees)
        ))
    }
}
