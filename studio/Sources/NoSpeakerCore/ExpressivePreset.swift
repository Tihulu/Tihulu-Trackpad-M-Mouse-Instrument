import Foundation

public enum ExpressivePresetError: LocalizedError, Equatable {
    case unsupportedInput, invalidChannel, targetConflict, invalidPatch
    public var errorDescription: String? {
        switch self {
        case .unsupportedInput: "Choose a supported input signal for this preset."
        case .invalidChannel: "Choose MIDI channel 1–16."
        case .targetConflict: "A route already owns this MIDI target. Edit that route or choose another channel."
        case .invalidPatch: "The resulting instrument exceeds its limits or is invalid."
        }
    }
}

/// Ready-to-edit controller mappings, not audio effects. Every route uses
/// the existing InstrumentPatch, calibration and SensorRouter.
public enum ExpressivePreset: String, CaseIterable, Identifiable, Sendable {
    case wah = "Wah Pedal (CC4)"
    case filter = "Filter Cutoff (CC74)"
    case whammy = "Whammy (Pitch Bend)"
    case expression = "Expression (CC11)"
    case volume = "Volume (CC7)"
    case vibrato = "Vibrato (CC1)"
    case pan = "Pan (CC10)"
    case xyFilter = "XY Filter & Resonance"
    public var id: String { rawValue }

    public var instructions: String {
        switch self {
        case .wah: "Map CC4 to your DAW's wah pedal position using MIDI Learn or controller assignment. No audio wah is generated here."
        case .filter: "CC74 is a conventional brightness/cutoff control; assign it to the receiver's filter if needed."
        case .whammy: "Pitch Bend uses the receiving instrument's configured bend range; this preset does not change it."
        case .expression: "CC11 controls expression on compatible instruments."
        case .volume: "CC7 controls MIDI channel volume on compatible instruments."
        case .vibrato: "CC1 modulation can control vibrato if assigned in the receiving instrument."
        case .pan: "CC10 is conventional MIDI pan. The existing router resets generic CCs to zero on release; configure a separate receiver if that is undesirable."
        case .xyFilter: "X sends CC74 cutoff, Y sends CC71 resonance. Assign both in the DAW. Both axes require a compatible input."
        }
    }

    public static let sources: [SensorSource] = [.trackpad,.magicMouse,.touchBar,.lid,.phone,.tablet,.camera]
    public static func signals(for source: SensorSource) -> [SensorSignal] {
        switch source {
        case .trackpad, .magicMouse: [.x,.y,.contactSize]
        case .touchBar: [.x]
        case .lid: [.angle]
        case .phone, .tablet: [.x,.y,.angle,.speed]
        case .camera: [.x,.y,.gesture]
        default: []
        }
    }

    public func supports(source: SensorSource, signal: SensorSignal) -> Bool {
        let signals = Self.signals(for: source)
        if self == .xyFilter { return signal == .x && signals.contains(.x) && signals.contains(.y) }
        return signals.contains(signal)
    }

    public func appending(to patch: InstrumentPatch, source: SensorSource, signal: SensorSignal,
                          channel: Int, inverted: Bool = false) throws -> InstrumentPatch {
        guard (0...15).contains(channel) else { throw ExpressivePresetError.invalidChannel }
        guard supports(source: source, signal: signal) else { throw ExpressivePresetError.unsupportedInput }
        guard patch.isValid else { throw ExpressivePresetError.invalidPatch }
        let targets: [(SensorSignal, SensorDestination)]
        switch self {
        case .wah: targets = [(signal,.init(.controlChange, channel: channel, number: 4))]
        case .filter: targets = [(signal,.init(.controlChange, channel: channel, number: 74))]
        case .whammy: targets = [(signal,.init(.pitchBend, channel: channel))]
        case .expression: targets = [(signal,.init(.controlChange, channel: channel, number: 11))]
        case .volume: targets = [(signal,.init(.controlChange, channel: channel, number: 7))]
        case .vibrato: targets = [(signal,.init(.controlChange, channel: channel, number: 1))]
        case .pan: targets = [(signal,.init(.controlChange, channel: channel, number: 10))]
        case .xyFilter: targets = [(.x,.init(.controlChange, channel: channel, number: 74)),
                                   (.y,.init(.controlChange, channel: channel, number: 71))]
        }
        let occupied = Set(patch.routes.map(\.destination))
        guard targets.allSatisfy({ !occupied.contains($0.1) }) else { throw ExpressivePresetError.targetConflict }
        var result = patch
        result.routes += targets.map { input, target in
            SensorMapping(id: UUID().uuidString, source: source, signal: input, destination: target,
                          calibration: .init(inverted: inverted))
        }
        guard result.isValid else { throw ExpressivePresetError.invalidPatch }
        return result
    }
}
