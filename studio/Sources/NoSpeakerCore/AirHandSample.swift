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
