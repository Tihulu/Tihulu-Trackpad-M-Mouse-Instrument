import Foundation

/// A manually supplied starting value is not DAW feedback. An adapter with
/// verified feedback can construct a gesture using the actual wire value.
public struct RelativeControlSettings: Codable, Equatable, Sendable {
    public var reference: Double
    public var gain: Double
    public init(reference: Double, gain: Double = 1) {
        self.reference = reference; self.gain = gain
    }
    public var isValid: Bool {
        reference.isFinite && (0...1).contains(reference) &&
        gain.isFinite && (0.25...4).contains(gain)
    }
}

/// Clutched, displacement-based control. The first sample only anchors.
/// No accumulated drift or endpoint overshoot; returning to the origin
/// returns to the original wire value. The caller owns release and timing.
public struct RelativeControlGesture: Sendable {
    private let origin: Double
    private let reference: Int
    private let lower: Int
    private let upper: Int
    private let gain: Double
    private let smoothingMS: Int
    private var filtered: Double
    private var previousTime: Double
    private var previousValue: Int
    public init?(input: Double, timestamp: Double, reference: Int, lower: Int,
                 upper: Int, gain: Double = 1, smoothingMS: Int = 0) {
        guard input.isFinite, (0...1).contains(input), timestamp.isFinite, timestamp >= 0,
              (0...16383).contains(lower), (lower...16383).contains(upper),
              (lower...upper).contains(reference), gain.isFinite, (0.25...4).contains(gain),
              (0...250).contains(smoothingMS) else { return nil }
        origin = input; self.reference = reference; self.lower = lower; self.upper = upper
        self.gain = gain; self.smoothingMS = smoothingMS
        filtered = input; previousTime = timestamp; previousValue = reference
    }
    /// nil means no new wire value. Invalid samples leave the gesture intact;
    /// source adapters must still enforce their own freshness and release gates.
    public mutating func update(input: Double, timestamp: Double) -> Int? {
        guard input.isFinite, (0...1).contains(input), timestamp.isFinite,
              timestamp >= previousTime else { return nil }
        if smoothingMS > 0 {
            let alpha = 1 - exp(-(timestamp - previousTime) * 1000 / Double(smoothingMS))
            filtered += alpha * (input - filtered)
        } else { filtered = input }
        previousTime = timestamp
        let raw = Double(reference) + (filtered - origin) * Double(upper - lower) * gain
        let value = Int(min(Double(upper), max(Double(lower), raw)).rounded())
        guard value != previousValue else { return nil }
        previousValue = value
        return value
    }
}
