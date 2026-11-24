import Foundation

/// Host-defined 25 chromatic logical keys plus a separately mapped pedal.
/// Default notes 48...72 (C3–C5, middle C = C4). No arbitrary remote MIDI.
public enum RemotePiano {
    public static let keySignals: [SensorSignal] = [
        .pianoKey0, .pianoKey1, .pianoKey2, .pianoKey3, .pianoKey4, .pianoKey5, .pianoKey6, .pianoKey7, .pianoKey8,
        .pianoKey9, .pianoKey10, .pianoKey11, .pianoKey12, .pianoKey13, .pianoKey14, .pianoKey15, .pianoKey16, .pianoKey17,
        .pianoKey18, .pianoKey19, .pianoKey20, .pianoKey21, .pianoKey22, .pianoKey23, .pianoKey24
    ]
    public static let signals = keySignals + [.pianoSustain]
    public static let sustainBit = 1 << 25
    public static let maximumMask = (1 << 26) - 1

    public static func permits(_ route: SensorMapping) -> Bool {
        guard signals.contains(route.signal) else { return true }
        guard route.source == .phone || route.source == .tablet,
              (route.calibration.apply(1) ?? -1) >= route.threshold else { return false }
        return route.signal == .pianoSustain ? route.destination.kind == .sustain : route.destination.kind == .note
    }

    public static func routes(source: SensorSource = .phone) -> [SensorMapping] {
        guard source == .phone || source == .tablet else { return [] }
        return keySignals.enumerated().map { index, signal in
            .init(id: UUID().uuidString, source: source, signal: signal,
                  destination: .init(.note, number: 48 + index), velocity: 100)
        } + [.init(id: UUID().uuidString, source: source, signal: .pianoSustain,
                   destination: .init(.sustain))]
    }
}
