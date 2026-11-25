import Foundation

/// Six host-mapped controls. Switches are owned momentary/latched states,
/// not MIDI program changes or a claim of a built-in audio effects engine.
public enum RemotePedalboard {
    public static let signals: [SensorSignal] = [
        .pedalExpression, .pedalVolume, .pedalWah, .pedalSustain, .pedalSwitch1, .pedalSwitch2
    ]
    public static let maximumMask = 63
    public static func validSnapshot(mask: Int, levels: [Double]) -> Bool {
        guard (0...maximumMask).contains(mask), levels.count == signals.count else { return false }
        return levels.enumerated().allSatisfy { index, value in
            guard value.isFinite, (0...1).contains(value) else { return false }
            let active = mask & (1 << index) != 0
            if !active { return value == 0 }
            return index < 3 || value == 1
        }
    }
    public static func permits(_ route: SensorMapping) -> Bool {
        guard let index = signals.firstIndex(of: route.signal) else { return true }
        guard route.source.isGroupRemote else { return false }
        if index < 3 { return ContinuousResponse.isContinuous(route.destination) }
        if index == 3 {
            return route.destination.kind == .sustain && (route.calibration.apply(1) ?? -1) >= route.threshold
        }
        // Binary switches must remain exact 0/127, with an off release.
        return route.destination.kind == .controlChange &&
            route.calibration == SensorCalibration() &&
            (route.response == nil || route.response == ContinuousResponse()) &&
            ContinuousResponse.defaultRelease(route.destination) == 0
    }
    public static func routes(source: SensorSource = .phone) -> [SensorMapping] {
        guard source == .phone || source == .tablet else { return [] }
        let destinations: [SensorDestination] = [
            .init(.controlChange, number: 11), .init(.controlChange, number: 7),
            .init(.controlChange, number: 74), .init(.sustain),
            .init(.controlChange, number: 80), .init(.controlChange, number: 81)
        ]
        return zip(signals, destinations).map { signal, destination in
            .init(id: UUID().uuidString, source: source, signal: signal, destination: destination)
        }
    }
}
