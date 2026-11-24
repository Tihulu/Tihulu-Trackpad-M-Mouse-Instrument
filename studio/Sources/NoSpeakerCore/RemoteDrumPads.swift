import Foundation

/// Fixed logical pad IDs; no client-supplied MIDI channel, note or velocity.
public enum RemoteDrumPads {
    public static let signals: [SensorSignal] = [.drumPad1,.drumPad2,.drumPad3,.drumPad4,.drumPad5,.drumPad6,.drumPad7,.drumPad8]
    public static let defaults: [AirDrumPreset] = [.kick,.snare,.closedHiHat,.openHiHat,.lowTom,.highTom,.crash,.ride]
    public static func permits(_ route: SensorMapping) -> Bool {
        guard signals.contains(route.signal) else { return true }
        return (route.source == .phone || route.source == .tablet) &&
            route.destination.kind == .note &&
            (route.calibration.apply(1) ?? -1) >= route.threshold
    }
    public static func routes(source: SensorSource = .phone) -> [SensorMapping] {
        guard source == .phone || source == .tablet else { return [] }
        return zip(signals, defaults).map { signal, drum in
            .init(id: UUID().uuidString, source: source, signal: signal,
                  destination: .init(.note, channel: 9, number: drum.note), velocity: 100)
        }
    }
}
