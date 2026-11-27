import Foundation

/// A bounded, monotonic tap-tempo estimator. A long pause begins a new series.
public struct TapTempo: Sendable {
    private var taps: [Double] = []
    public init() {}

    public static func safeBPM(_ value: Double) -> Double {
        value.isFinite ? min(300, max(20, value)) : 120
    }

    public mutating func tap(at time: Double) -> Double? {
        guard time.isFinite, time >= 0 else { return nil }
        if let last = taps.last {
            // Invalid or repeated timestamps must not replace accepted history.
            guard time > last else { return nil }
            let gap = time - last
            // Compare the minimum against the rounded absolute timestamp;
            // subtraction can turn a nominal 200 ms tap into 0.199999...
            // Likewise allow a rounded nominal 3 s boundary, but only when
            // the clock can still resolve the 200 ms minimum interval.
            let roundedMaximum = time == last + 3 && time.ulp < 0.2
            if time < last + 0.2 || (gap > 3 && !roundedMaximum) {
                taps = [time]
                return nil
            }
        }
        taps.append(time)
        if taps.count > 5 { taps.removeFirst() }
        guard taps.count >= 2, let first = taps.first else { return nil }
        return Self.safeBPM((60 * Double(taps.count - 1) / (time - first)).rounded())
    }
}
