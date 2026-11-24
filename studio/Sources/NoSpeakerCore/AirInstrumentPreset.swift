import Foundation

/// Real single-hand mappings using existing sensor routes, not an audio synth.
public enum AirInstrumentPreset: String, CaseIterable, Identifiable, Sendable {
    case theremin = "Air Theremin"
    case pinchNote = "Pinch Note"
    case wah = "Air Wah"
    public var id: String { rawValue }
    public var instructions: String {
        switch self {
        case .theremin: "Pinch to play a fixed root note, move X to bend pitch and Y for expression. Set the receiving synth's bend range manually. Use a dedicated monophonic instrument/channel."
        case .pinchNote: "Pinch to play the assigned note; open the fingers to release."
        case .wah: "Open and close thumb/index to sweep CC4; assign to your DAW wah pedal."
        }
    }
    public func appending(to patch: InstrumentPatch, channel: Int, note: Int = 60) throws -> InstrumentPatch {
        guard (0...15).contains(channel) else { throw ExpressivePresetError.invalidChannel }
        guard (0...127).contains(note), patch.isValid else { throw ExpressivePresetError.invalidPatch }
        let gate = SensorMapping(id: UUID().uuidString, source: .camera, signal: .gesture,
                                 destination: .init(.note, channel: channel, number: note),
                                 calibration: .init(inverted: true), threshold: 0.80, hysteresis: 0.12)
        let routes: [SensorMapping]
        switch self {
        case .theremin:
            routes = [
                .init(id: UUID().uuidString, source: .camera, signal: .x,
                      destination: .init(.pitchBend, channel: channel),
                      calibration: .init(minimum: 0.15, maximum: 0.85),
                      response: .init(smoothingMS: 60)),
                .init(id: UUID().uuidString, source: .camera, signal: .y,
                      destination: .init(.controlChange, channel: channel, number: 11),
                      calibration: .init(minimum: 0.15, maximum: 0.85),
                      response: .init(smoothingMS: 60)),
                gate
            ]
        case .pinchNote: routes = [gate]
        case .wah:
            routes = [.init(id: UUID().uuidString, source: .camera, signal: .gesture,
                            destination: .init(.controlChange, channel: channel, number: 4),
                            response: .init(smoothingMS: 60))]
        }
        let occupied = Set(patch.routes.map(\.destination))
        guard routes.allSatisfy({ !occupied.contains($0.destination) }) else { throw ExpressivePresetError.targetConflict }
        var result = patch
        result.routes += routes
        guard result.isValid else { throw ExpressivePresetError.invalidPatch }
        return result
    }
}

/// Explicit two-point calibration from derived hand values; no images stored.
/// Applying is an edit to the existing routes and preserves curves and gates.
public struct AirRangeCapture: Equatable, Sendable {
    public var signal: SensorSignal
    public var first: Double?
    public var second: Double?
    public init(signal: SensorSignal = .gesture, first: Double? = nil, second: Double? = nil) {
        self.signal = signal; self.first = first; self.second = second
    }
    public func value(from hand: AirHandSample) -> Double? {
        switch signal {
        case .x: hand.x
        case .y: hand.y
        case .gesture: hand.aperture
        default: nil
        }
    }
    public var bounds: ClosedRange<Double>? {
        guard [.x,.y,.gesture].contains(signal), let first, let second,
              first.isFinite, second.isFinite, (0...1).contains(first), (0...1).contains(second),
              abs(first-second) >= 0.05 else { return nil }
        return min(first,second)...max(first,second)
    }
    public func applying(to patch: InstrumentPatch) throws -> InstrumentPatch {
        guard let bounds, patch.isValid else { throw ExpressivePresetError.invalidPatch }
        var result = patch
        var count = 0
        for i in result.routes.indices where result.routes[i].source == .camera && result.routes[i].signal == signal {
            result.routes[i].calibration.minimum = bounds.lowerBound
            result.routes[i].calibration.maximum = bounds.upperBound
            count += 1
        }
        guard count > 0, result.isValid else { throw ExpressivePresetError.invalidPatch }
        return result
    }
}
