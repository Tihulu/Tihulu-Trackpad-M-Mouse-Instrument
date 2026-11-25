import Foundation

/// Geometry-only, bounded strum detector. Coordinates are normalized
/// after camera orientation calibration. No MIDI or ownership side effects.
public struct AirStringCrossing: Sendable {
    public struct Hit: Equatable, Sendable {
        public let string: Int
        public let velocity: Int
    }

    public let stringCount: Int
    public let hysteresis: Double
    private var previous: Double?
    private var lastTime: Double?
    private var sides: [Int]
    public init?(stringCount: Int = 3, hysteresis: Double = 0.025) {
        guard (3...8).contains(stringCount), hysteresis.isFinite,
              (0.005...0.04).contains(hysteresis) else { return nil }
        self.stringCount = stringCount
        self.hysteresis = hysteresis
        sides = Array(repeating: 0, count: stringCount)
    }

    public mutating func reset() {
        previous = nil; lastTime = nil
        sides = Array(repeating: 0, count: stringCount)
    }

    /// A first sample merely primes the detector. Missing, stale, duplicate
    /// or malformed samples clear it. Multiple crossed strings are returned
    /// in physical stroke order even at reduced camera frame rates.
    public mutating func observe(position: Double?, time: Double) -> [Hit] {
        guard let position, position.isFinite, (0...1).contains(position),
              time.isFinite, time >= 0 else { reset(); return [] }
        if let lastTime, time <= lastTime {
            reset(); return []
        }
        if let lastTime, time - lastTime >= 0.25 { reset() }
        let prior = previous
        let dt = lastTime.map { time - $0 }
        previous = position; lastTime = time
        var crossed: [Int] = []
        for i in 0..<stringCount {
            let center = Double(i + 1) / Double(stringCount + 1)
            let side = position < center - hysteresis ? -1 : (position > center + hysteresis ? 1 : 0)
            guard side != 0 else { continue }
            if sides[i] != 0 && sides[i] != side { crossed.append(i) }
            sides[i] = side
        }
        guard let prior, let dt, dt > 0 else { return [] }
        if position < prior { crossed.reverse() }
        // Cap the velocity before converting to Int, including tiny dt.
        let scaled = min(1, abs(position-prior) / max(dt,0.001) / 5)
        let velocity = 32 + Int((95 * scaled).rounded())
        return crossed.map { Hit(string: $0, velocity: velocity) }
    }
}
