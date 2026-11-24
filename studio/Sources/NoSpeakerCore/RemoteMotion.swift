import Foundation

/// Browser DeviceOrientation angles in degrees (device coordinates).
/// These are Euler controls, not a claim of absolute compass heading.
public struct RemoteOrientation: Equatable, Sendable {
    public let alpha: Double
    public let beta: Double
    public let gamma: Double

    public init?(alpha: Double, beta: Double, gamma: Double) {
        guard alpha.isFinite, beta.isFinite, gamma.isFinite,
              (0..<360).contains(alpha), (-180...180).contains(beta),
              (-90...90).contains(gamma) else { return nil }
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }
}

public struct RemoteMotionVector: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    /// Reject outliers instead of turning malformed input into maximum MIDI.
    /// Units and bounds must be selected by the adapter, not the client.
    public init?(x: Double, y: Double, z: Double, limit: Double) {
        guard limit.isFinite, limit > 0, limit <= 10_000,
              [x,y,z].allSatisfy({ $0.isFinite && abs($0) <= limit }) else { return nil }
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { sqrt(x*x + y*y + z*z) }
}

public struct RemoteTiltValues: Equatable, Sendable {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
}

/// Pure relative Euler control. 0.5 is the calibrated neutral.
/// No hardware access, permissions, transport, or MIDI ownership here.
public struct RemoteTiltCalibration: Equatable, Sendable {
    public let neutral: RemoteOrientation
    public let sweepDegrees: Double

    public init?(neutral: RemoteOrientation, sweepDegrees: Double = 45) {
        guard sweepDegrees.isFinite, (5...90).contains(sweepDegrees) else { return nil }
        self.neutral = neutral
        self.sweepDegrees = sweepDegrees
    }

    public func normalize(_ sample: RemoteOrientation) -> RemoteTiltValues {
        func shortest(_ delta: Double) -> Double {
            var value = delta.truncatingRemainder(dividingBy: 360)
            if value >= 180 { value -= 360 }
            if value < -180 { value += 360 }
            return value
        }
        func scale(_ degrees: Double) -> Double {
            min(1, max(0, 0.5 + degrees / (2 * sweepDegrees)))
        }
        return .init(yaw: scale(shortest(sample.alpha-neutral.alpha)),
                     pitch: scale(shortest(sample.beta-neutral.beta)),
                     roll: scale(sample.gamma-neutral.gamma))
    }
}

/// Per-stream local-receipt freshness gate. A rejected sample disarms the
/// stream; rearming is explicit. Never use an untrusted client's clock.
public struct RemoteMotionFreshness: Sendable {
    public static let timeout = 0.35
    private var lastReceipt: Double?
    public init() {}
    public var isArmed: Bool { lastReceipt != nil }

    @discardableResult
    public mutating func arm(receipt: Double, now: Double) -> Bool {
        lastReceipt = nil
        guard Self.fresh(receipt, now: now) else { return false }
        lastReceipt = receipt
        return true
    }

    public mutating func accept(receipt: Double, now: Double) -> Bool {
        guard let last = lastReceipt, Self.fresh(receipt, now: now),
              now-last < Self.timeout, receipt > last else {
            disarm()
            return false
        }
        lastReceipt = receipt
        return true
    }

    /// True exactly when an armed stream expired; caller releases ownership.
    @discardableResult
    public mutating func expire(now: Double) -> Bool {
        guard let last = lastReceipt else { return false }
        guard !Self.fresh(last, now: now) else { return false }
        disarm()
        return true
    }

    public mutating func disarm() { lastReceipt = nil }

    private static func fresh(_ receipt: Double, now: Double) -> Bool {
        receipt.isFinite && now.isFinite && receipt >= 0 && receipt <= now &&
            now-receipt < timeout
    }
}

/// Magnitudes for shake/speed controls. Acceleration must exclude gravity;
/// a missing sensor is unavailable, never synthesized from another sensor.
public enum RemoteMotionNormalizer {
    public static func acceleration(x: Double, y: Double, z: Double) -> Double? {
        normalized(x: x, y: y, z: z, limit: 100, fullScale: 20)
    }

    public static func rotationRate(x: Double, y: Double, z: Double) -> Double? {
        normalized(x: x, y: y, z: z, limit: 2_000, fullScale: 360)
    }

    private static func normalized(x: Double, y: Double, z: Double,
                                   limit: Double, fullScale: Double) -> Double? {
        guard let vector = RemoteMotionVector(x: x, y: y, z: z, limit: limit) else { return nil }
        return min(1, vector.magnitude/fullScale)
    }
}
