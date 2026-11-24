import Foundation

/// Only normalized 2D landmarks, not images, depth, physical force or identity.
public struct AirHandPoint: Sendable {
    public let x: Double
    public let y: Double
    public let confidence: Double
    public init(x: Double, y: Double, confidence: Double) {
        self.x = x; self.y = y; self.confidence = confidence
    }
    public var isReliable: Bool {
        x.isFinite && y.isFinite && confidence.isFinite &&
        (0...1).contains(x) && (0...1).contains(y) && (0.65...1).contains(confidence)
    }
    public func distance(to other: Self) -> Double { hypot(x-other.x, y-other.y) }
}

public struct AirHandSample: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let aperture: Double
    private init(x: Double, y: Double, aperture: Double) {
        self.x = x; self.y = y; self.aperture = aperture
    }
    public init?(thumb: AirHandPoint, index: AirHandPoint, wrist: AirHandPoint, middleBase: AirHandPoint) {
        guard [thumb,index,wrist,middleBase].allSatisfy(\.isReliable) else { return nil }
        let palm = wrist.distance(to: middleBase)
        guard palm >= 0.025 else { return nil }
        x = index.x
        y = index.y
        // Relative 2D aperture, normalized against palm length.
        aperture = min(1, max(0, thumb.distance(to: index) / (palm * 1.5)))
    }
}

/// Rotates normalized, Y-up control coordinates, not camera images.
public enum AirControlOrientation: String, CaseIterable, Identifiable, Sendable {
    case upright = "Upright"
    case clockwise = "90° clockwise"
    case upsideDown = "180°"
    case counterclockwise = "90° counterclockwise"
    public var id: String { rawValue }
}

extension AirHandSample {
    public func oriented(_ orientation: AirControlOrientation, mirrorX: Bool) -> Self {
        let point: (Double, Double)
        switch orientation {
        case .upright: point = (x,y)
        case .clockwise: point = (y,1-x)
        case .upsideDown: point = (1-x,1-y)
        case .counterclockwise: point = (1-y,x)
        }
        return .init(x: mirrorX ? 1-point.0 : point.0, y: point.1, aperture: aperture)
    }
}

/// Require two fresh consecutive reliable samples to acquire a hand.
/// Loss, non-monotonic input or a gap immediately clears acquisition.
/// No extrapolation, identity tracking or fabricated held position.
public struct AirTrackingGate: Sendable {
    public static let maximumGap = 0.35
    private var last: Double?
    private var count = 0
    public init() {}
    public mutating func reset() { last = nil; count = 0 }
    public mutating func accept(_ sample: AirHandSample?, at time: Double, now: Double) -> AirHandSample? {
        guard let sample, time.isFinite, now.isFinite, time >= 0, now >= time,
              now-time < Self.maximumGap else { reset(); return nil }
        if let previous = last {
            guard time > previous else { reset(); return nil }
            if time-previous >= Self.maximumGap { reset() }
        }
        last = time
        count = min(2, count+1)
        return count == 2 ? sample : nil
    }
}
