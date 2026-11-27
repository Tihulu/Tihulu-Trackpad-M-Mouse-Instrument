import Foundation

/// Optional continuous-target settings. Ranges are normalized, independent
/// of wire resolution. Release is absolute (not remapped by the sweep range).
/// Nil on legacy routes preserves their full-range, immediate response.
public struct ContinuousResponse: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var smoothingMS: Int
    public var release: Double?
    /// nil preserves legacy absolute position. Reference is explicitly manual until feedback is wired.
    public var relative: RelativeControlSettings?
    public init(minimum: Double = 0, maximum: Double = 1, smoothingMS: Int = 0,
                release: Double? = nil, relative: RelativeControlSettings? = nil) {
        self.minimum = minimum
        self.maximum = maximum
        self.smoothingMS = smoothingMS
        self.release = release
        self.relative = relative
    }
    public var isValid: Bool {
        minimum.isFinite && maximum.isFinite &&
        (0...1).contains(minimum) && (0...1).contains(maximum) && minimum <= maximum &&
        (0...250).contains(smoothingMS) &&
        (release.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
        (relative.map { $0.isValid && $0.reference >= minimum && $0.reference <= maximum } ?? true)
    }
    public static func isContinuous(_ target: SensorDestination) -> Bool {
        target.kind == .controlChange || target.kind == .pitchBend
    }
    /// Relative displacement is for expressive continuous lanes, not switches,
    /// bank select, RPN/NRPN, data entry or channel-mode messages.
    public static func permitsRelative(_ target: SensorDestination) -> Bool {
        target.isValid && (target.kind == .pitchBend ||
            (target.kind == .controlChange && !(64...69).contains(target.number) &&
             ![0,6,32,38,96,97,98,99,100,101].contains(target.number)))
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
        let relativeTargets = Set(routes.filter { $0.response?.relative != nil }.map(\.destination))
        var seenRelative: Set<SensorDestination> = []
        for route in routes {
            // A manually referenced gesture cannot safely take over a shared
            // destination from another owner with a different current value.
            if relativeTargets.contains(route.destination),
               !seenRelative.insert(route.destination).inserted { return nil }
            guard route.isValid else { return nil }
            let target = route.destination
            let value = route.response?.releaseValue(for: target) ?? defaultRelease(target)
            if let existing = values[target], existing != value { return nil }
            values[target] = value
        }
        return values
    }
}
