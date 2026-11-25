import Foundation

/// Physical landmarks only. Hand identity must be supplied by the native adapter.
public struct AirFingerChain: Sendable {
    public let base: AirHandPoint
    public let joint: AirHandPoint
    public let tip: AirHandPoint
    public init(base: AirHandPoint, joint: AirHandPoint, tip: AirHandPoint) {
        self.base = base; self.joint = joint; self.tip = tip
    }

    /// Classify extension using joint geometry, not screen orientation.
    /// The ambiguous middle band deliberately yields no classification.
    public var extended: Bool? {
        guard [base, joint, tip].allSatisfy(\.isReliable) else { return nil }
        let ax = base.x - joint.x, ay = base.y - joint.y
        let bx = tip.x - joint.x, by = tip.y - joint.y
        let length = hypot(ax, ay) * hypot(bx, by)
        guard length > 0.00001 else { return nil }
        let cosine = (ax * bx + ay * by) / length
        if cosine <= -0.78 { return true }
        if cosine >= -0.35 { return false }
        return nil
    }
}

public enum AirFingerCount {
    public static func classify(_ fingers: [AirFingerChain]) -> Int? {
        guard fingers.count == 5 else { return nil }
        let states = fingers.compactMap(\.extended)
        guard states.count == 5 else { return nil }
        return states.filter { $0 }.count
    }
}

/// A held pinch must never retrigger after loss or a chord change.
/// Emits desired slot only while pinched; nil means release.
public struct AirPinchGate: Sendable {
    private var armed = false
    private var heldSlot: Int?
    private var pinched = false
    public init() {}

    public mutating func reset() {
        armed = false; heldSlot = nil; pinched = false
    }

    public mutating func update(aperture: Double?, selectedSlot: Int?) -> Int? {
        guard let aperture, aperture.isFinite, (0...1).contains(aperture),
              selectedSlot.map({ (1...5).contains($0) }) ?? true else {
            reset(); return nil
        }
        if aperture >= 0.35 {
            armed = true; heldSlot = nil; pinched = false
            return nil
        }
        guard armed else { return nil }
        if !pinched && aperture <= 0.18 {
            pinched = true
            heldSlot = selectedSlot
        }
        if heldSlot != selectedSlot { heldSlot = nil }
        return heldSlot
    }
}
