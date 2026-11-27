import Foundation

/// Converts a single wrapped angle into an origin-relative normalized input.
/// This is not orientation fusion, MIDI output, or a freshness gate. The
/// adapter must provide accepted, ordered, local-receipt samples in degrees,
/// bind one physical axis and enforce its existing arm/release deadlines.
public struct RelativeAngularClutch: Sendable {
    public enum Result: Equatable, Sendable {
        case anchored(Double), position(Double), releaseRequired, blocked
    }
    private enum Phase: Sendable { case ready, active, blocked }
    private let sweepDegrees: Double
    private let maximumStepDegrees: Double
    private var phase = Phase.ready
    private var previousAngle: Double = 0
    private var displacement: Double = 0
    private var lastReceipt: Double?

    /// Sweep is center-to-edge travel. An ambiguous or implausibly large
    /// adjacent step must be rejected, not guessed from the wrapped sample.
    public init?(sweepDegrees: Double = 45, maximumStepDegrees: Double = 90) {
        guard sweepDegrees.isFinite, (5...180).contains(sweepDegrees),
              maximumStepDegrees.isFinite, (1...179).contains(maximumStepDegrees) else { return nil }
        self.sweepDegrees = sweepDegrees
        self.maximumStepDegrees = maximumStepDegrees
    }

    /// Retire every finite, advancing observed receipt, including rejected
    /// angles and samples while blocked. Invalid clocks cannot poison rearm.
    private mutating func observe(receipt: Double) -> Bool {
        guard receipt.isFinite, receipt >= 0,
              lastReceipt.map({ receipt > $0 }) ?? true else { return false }
        lastReceipt = receipt
        return true
    }

    private func valid(angle: Double) -> Bool {
        angle.isFinite && (0..<360).contains(angle)
    }

    /// The adapter calls begin only on a newly admitted explicit clutch.
    /// The origin is always 0.5; feed it into the existing relative engine
    /// once, rather than independently transforming the same MIDI parameter.
    public mutating func begin(angle: Double, receipt: Double) -> Result {
        guard observe(receipt: receipt), case .ready = phase,
              valid(angle: angle) else { return invalidate() }
        previousAngle = angle; displacement = 0
        phase = .active
        return .anchored(0.5)
    }

    public mutating func update(angle: Double, receipt: Double) -> Result {
        let advanced = observe(receipt: receipt)
        guard case .active = phase else { return .blocked }
        guard advanced, valid(angle: angle) else { return invalidate() }
        var step = angle - previousAngle
        if step > 180 { step -= 360 }
        if step < -180 { step += 360 }
        guard abs(step) <= maximumStepDegrees else { return invalidate() }
        let next = displacement + step
        // Bound unwrapped travel without clipping internal displacement.
        // Silent clipping would lose the original anchor on the return path.
        guard abs(next) <= 3600 else { return invalidate() }
        displacement = next; previousAngle = angle
        return .position(min(1, max(0, 0.5 + displacement / (2 * sweepDegrees))))
    }

    /// A fault retires the clutch. No automatic re-anchor while held.
    public mutating func invalidate() -> Result {
        let wasActive: Bool
        if case .active = phase { wasActive = true } else { wasActive = false }
        phase = .blocked; displacement = 0
        return wasActive ? .releaseRequired : .blocked
    }

    /// Only call after an actual release or explicit disarm/re-arm boundary.
    /// Keep the receipt watermark so queued samples cannot re-anchor.
    @discardableResult
    public mutating func end() -> Result {
        let wasActive: Bool
        if case .active = phase { wasActive = true } else { wasActive = false }
        phase = .ready; displacement = 0
        return wasActive ? .releaseRequired : .blocked
    }
}
