import Foundation

/// Shared physical and replay input. Native adapter resolves chirality before
/// calling this engine; ambiguous or missing hands are represented by nil.
public struct AirDualHandPerformance: Sendable {
    public static let signals: [SensorSignal] = [.airChord1, .airChord2, .airChord3, .airChord4, .airChord5]
    public static let defaultBank = [[60,64,67],[62,65,69],[64,67,71],[65,69,72],[67,71,74]]
    private var selection = AirChordSelection(slots: defaultBank)!
    private var pinch = AirPinchGate()
    public private(set) var soundingSlot: Int?
    public init() {}

    public mutating func reset() {
        _ = selection.invalidate()
        pinch.reset()
        soundingSlot = nil
    }

    public mutating func receive(count: Int?, confidence: Double, helper: AirHandSample?,
                                 time: Double, now: Double) -> Int? {
        guard time.isFinite, now.isFinite, time >= 0, now >= time,
              now - time < 0.25, let helper else { reset(); return nil }
        let change = selection.observe(count: count, confidence: confidence, time: time)
        if change == .releaseOwned {
            pinch.reset()
            soundingSlot = nil
            return nil
        }
        soundingSlot = pinch.update(aperture: helper.aperture, selectedSlot: selection.selectedSlot)
        return soundingSlot
    }

    public static func permits(_ route: SensorMapping) -> Bool {
        guard signals.contains(route.signal) else { return true }
        return route.source == .camera && route.destination.kind == .note &&
            (route.calibration.apply(1) ?? -1) >= route.threshold
    }

    public static func routes(channel: Int = 0) -> [SensorMapping] {
        guard (0...15).contains(channel) else { return [] }
        return zip(signals, defaultBank).enumerated().flatMap { index, pair in
            pair.1.map { note in
                SensorMapping(id: "air-chord-\(index)-\(note)", source: .camera,
                              signal: pair.0, destination: .init(.note, channel: channel, number: note))
            }
        }
    }
}
