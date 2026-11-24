import Foundation

/// One onset detector per physical acceleration stream. Layered notes on
/// the same source must agree on onset sensitivity, but may differ in velocity.
public enum AirDrumPreset: String, CaseIterable, Identifiable, Sendable {
    case kick, snare, closedHiHat, openHiHat, lowTom, highTom, crash, ride
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .closedHiHat: "Closed hi-hat"
        case .openHiHat: "Open hi-hat"
        case .lowTom: "Low tom"
        case .highTom: "High tom"
        case .crash: "Crash cymbal"
        case .ride: "Ride cymbal"
        }
    }
    public var note: Int {
        switch self {
        case .kick: 36
        case .snare: 38
        case .closedHiHat: 42
        case .openHiHat: 46
        case .lowTom: 45
        case .highTom: 50
        case .crash: 49
        case .ride: 51
        }
    }
    public func route(id: String = UUID().uuidString, source: SensorSource = .phone) -> SensorMapping {
        .init(id: id, source: source, signal: .airStrike,
              destination: .init(.note, channel: 9, number: note),
              threshold: 0.45, hysteresis: 0.25, velocity: 127)
    }
}

public enum AirDrumSensitivity {
    public static func settings(for route: SensorMapping) -> AirStrikeDetector.Settings? {
        guard route.signal == .airStrike, route.destination.kind == .note,
              route.source == .phone || route.source == .tablet else { return nil }
        return .init(threshold: route.threshold, resetThreshold: route.threshold-route.hysteresis)
    }
    /// Nil indicates invalid or conflicting detector settings.
    public static func settings(for routes: [SensorMapping]) -> [SensorSource: AirStrikeDetector.Settings]? {
        var result: [SensorSource: AirStrikeDetector.Settings] = [:]
        for route in routes where route.signal == .airStrike {
            guard let settings = settings(for: route) else { return nil }
            if let previous = result[route.source], previous != settings { return nil }
            result[route.source] = settings
        }
        return result
    }
}
