import Foundation

/// Optional continuous-target settings. Ranges are normalized, independent
/// of wire resolution. Release is absolute (not remapped by the sweep range).
/// Nil on legacy routes preserves their full-range, immediate response.
public struct ContinuousResponse: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var smoothingMS: Int
    public var release: Double?
    public init(minimum: Double = 0, maximum: Double = 1, smoothingMS: Int = 0,
                release: Double? = nil) {
        self.minimum = minimum
        self.maximum = maximum
        self.smoothingMS = smoothingMS
        self.release = release
    }
    public var isValid: Bool {
        minimum.isFinite && maximum.isFinite &&
        (0...1).contains(minimum) && (0...1).contains(maximum) && minimum <= maximum &&
        (0...250).contains(smoothingMS) &&
        (release.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
    public static func isContinuous(_ target: SensorDestination) -> Bool {
        target.kind == .controlChange || target.kind == .pitchBend
    }
    public static func wireValue(_ normalized: Double, target: SensorDestination) -> Int {
        guard normalized.isFinite else { return defaultRelease(target) }
        return Int((min(1, max(0, normalized)) * (target.kind == .pitchBend ? 16383 : 127)).rounded())
    }
    public static func defaultRelease(_ target: SensorDestination) -> Int {
        switch target.kind {
        case .note, .sustain: return 0
        case .pitchBend: return 8192
        case .controlChange: return [7,11].contains(target.number) ? 127 : 0
        }
    }
    public func releaseValue(for target: SensorDestination) -> Int {
        release.map { Self.wireValue($0, target: target) } ?? Self.defaultRelease(target)
    }
    public func output(_ value: Double, target: SensorDestination) -> Int {
        Self.wireValue(minimum + (maximum - minimum) * value, target: target)
    }
    /// Time-based one-pole filter, evaluated only on input samples. No
    /// background timer, first sample is immediate; release bypasses smoothing.
    public func smooth(_ value: Double, previous: Double, elapsed: Double) -> Double {
        guard smoothingMS > 0 else { return value }
        let dt = max(0, elapsed)
        let alpha = 1 - exp(-dt * 1000 / Double(smoothingMS))
        return previous + alpha * (value - previous)
    }
    /// Shared destinations must agree on the final release value. Different
    /// curves and ranges are allowed; the winning owner determines live value.
    public static func releaseValues(for routes: [SensorMapping]) -> [SensorDestination:Int]? {
        var values: [SensorDestination:Int] = [:]
        for route in routes {
            guard route.isValid else { return nil }
            let target = route.destination
            let value = route.response?.releaseValue(for: target) ?? defaultRelease(target)
            if let existing = values[target], existing != value { return nil }
            values[target] = value
        }
        return values
    }
}
