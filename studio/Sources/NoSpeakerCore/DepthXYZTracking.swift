import Foundation

/// Position of one measured landmark in the upright view. X increases to the
/// right, Y upwards and Z away from the camera, in meters. Sensor adapters
/// supply all three coordinates for the same point and acquisition.
public struct DepthXYZPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let meters: Double
    public let confidence: Double

    public init(x: Double, y: Double, meters: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.meters = meters
        self.confidence = confidence
    }

    public var isValid: Bool {
        (0...1).contains(x) && (0...1).contains(y) &&
        meters.isFinite && meters > 0 && (0.65...1).contains(confidence)
    }
}

/// Local camera calibration in display coordinates. Leaving any side of the
/// volume releases the complete input, including when the mapped axis is off.
public struct DepthXYZVolume: Codable, Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var bottom: Double
    public var top: Double
    public var nearMeters: Double
    public var farMeters: Double

    public init(left: Double = 0, right: Double = 1, bottom: Double = 0, top: Double = 1,
                nearMeters: Double = 0.25, farMeters: Double = 0.85) {
        self.left = left
        self.right = right
        self.bottom = bottom
        self.top = top
        self.nearMeters = nearMeters
        self.farMeters = farMeters
    }

    public var isValid: Bool {
        // Decimal UI steps can land one or two floating-point ULPs below
        // the minimum spacing. Permit round-off only; retain strict bounds.
        let epsilon = 1e-12
        return (0...1).contains(left) && (0...1).contains(right) && right - left >= 0.05 - epsilon &&
        (0...1).contains(bottom) && (0...1).contains(top) && top - bottom >= 0.05 - epsilon &&
        (0.1...3).contains(nearMeters) && (0.1...3).contains(farMeters) &&
        farMeters - nearMeters >= 0.1 - epsilon
    }

    public func normalize(_ point: DepthXYZPoint) -> DepthXYZLevels? {
        guard isValid, point.isValid,
              (left...right).contains(point.x), (bottom...top).contains(point.y),
              (nearMeters...farMeters).contains(point.meters) else { return nil }
        return DepthXYZLevels(x: (point.x - left) / (right - left),
                              y: (point.y - bottom) / (top - bottom),
                              z: (point.meters - nearMeters) / (farMeters - nearMeters))
    }
}

public struct DepthXYZLevels: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
}

/// Source-local monotonic timestamps, in seconds. A watchdog must poll even
/// during capture silence. Only fresh, consecutive measurements can acquire
/// the volume; no last-value hold or extrapolation on loss.
public struct DepthXYZTracking: Sendable {
    public let volume: DepthXYZVolume
    private var observed: Int64?
    private var clock: Int64?
    private var candidate: Int64?

    public init?(volume: DepthXYZVolume = .init()) {
        guard volume.isValid else { return nil }
        self.volume = volume
    }

    /// Keep time fences across loss or reorientation in this capture session.
    public mutating func reset() {
        candidate = nil
        if let clock { observed = max(observed ?? clock, clock) }
    }

    private mutating func receipt(_ now: Double) -> Int64? {
        guard let receipt = MobileAirCaptureFrame.nanoseconds(now),
              clock.map({ receipt >= $0 }) ?? true else { return nil }
        clock = receipt
        return receipt
    }

    public mutating func observe(_ point: DepthXYZPoint?, at time: Double, now: Double) -> DepthXYZLevels? {
        guard let receipt = receipt(now), let stamp = MobileAirCaptureFrame.nanoseconds(time),
              stamp <= receipt, receipt - stamp < MobileAirSendGate.freshNS,
              observed.map({ stamp > $0 }) ?? true,
              let point, let levels = volume.normalize(point) else {
            reset()
            return nil
        }
        let previous = candidate
        // A delayed watchdog must not allow a buffered measurement from
        // before the expired candidate's deadline to renew that candidate.
        if let previous, receipt - previous >= MobileAirSendGate.freshNS {
            let deadline = previous + MobileAirSendGate.freshNS
            guard stamp >= deadline else {
                reset()
                return nil
            }
            observed = stamp
            candidate = stamp
            return nil
        }
        observed = stamp
        candidate = stamp
        guard let previous, stamp - previous < MobileAirSendGate.freshNS else { return nil }
        return levels
    }

    /// True once when a timed-out acquisition is cleared (warm or active).
    public mutating func expire(now: Double) -> Bool {
        let stamp = receipt(now)
        guard let candidate else { return false }
        guard let stamp, stamp - candidate < MobileAirSendGate.freshNS else {
            reset()
            return true
        }
        return false
    }
}

public enum DepthXYZPitchAxis: String, Codable, CaseIterable, Identifiable, Sendable {
    case x, y, z
    public var id: Self { self }
}

/// One exclusive key family. Only keys in the Mac grant are playable; local
/// previews must explicitly provide their preview mask. Hysteresis limits
/// repeated attacks near the boundary of two adjacent authorized keys.
public struct DepthXYZKeys: Sendable {
    private let keys: [Int]
    private let axis: DepthXYZPitchAxis
    private var zone: Int?

    public init?(authorized: Int, axis: DepthXYZPitchAxis) {
        guard (1..<(1 << 25)).contains(authorized) else { return nil }
        keys = (0..<25).filter { authorized & (1 << $0) != 0 }
        self.axis = axis
    }

    public mutating func output(_ levels: DepthXYZLevels?) -> MobileAirOutput {
        guard let levels else { zone = nil; return .init() }
        let value: Double
        switch axis { case .x: value = levels.x; case .y: value = levels.y; case .z: value = levels.z }
        guard (0...1).contains(value) else { zone = nil; return .init() }
        let position = value * Double(keys.count)
        let chosen: Int
        if let previous = zone, position >= Double(previous) - 0.12 && position < Double(previous + 1) + 0.12 {
            chosen = previous
        } else { chosen = min(keys.count - 1, Int(position)) }
        zone = chosen
        return .init(keys: 1 << keys[chosen])
    }
}
