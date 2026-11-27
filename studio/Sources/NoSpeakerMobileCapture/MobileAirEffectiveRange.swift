import Foundation

/// Client-only calibration selection. Non-depth instruments do not consume
/// saved depth bounds. Depth instruments retain the existing core predicate.
struct MobileAirEffectiveRange: Equatable {
    let near: Double
    let far: Double

    static func resolve(usesDepth: Bool, near: Double, far: Double) -> Self? {
        if !usesDepth { return .init(near: 0.25, far: 0.85) }
        guard near.isFinite, far.isFinite, near >= 0.1, far <= 3,
              far - near >= 0.1 else { return nil }
        return .init(near: near, far: far)
    }
}
