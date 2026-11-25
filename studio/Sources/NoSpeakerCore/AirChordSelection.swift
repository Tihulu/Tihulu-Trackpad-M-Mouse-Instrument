import Foundation

/// Pure selection layer. No MIDI emission or camera ownership.
/// Caller supplies calibrated physical-hand identity, monotonic seconds and a
/// nil sample on tracking loss. An independent watchdog must call expire().
public struct AirChordSelection: Sendable {
    public enum Change: Equatable, Sendable {
        case unchanged
        case selected(slot: Int, notes: [Int])
        case releaseOwned
    }

    public let slots: [[Int]]
    public let debounce: Double
    public let maximumGap: Double
    public let minimumConfidence: Double
    public private(set) var selectedSlot: Int?
    private var pendingSlot: Int?
    private var pendingSince: Double?
    private var lastTime: Double?
    private var armed = false

    public init?(slots: [[Int]], debounce: Double = 0.12,
                 maximumGap: Double = 0.25, minimumConfidence: Double = 0.75) {
        guard slots.count == 5,
              slots.allSatisfy({ !$0.isEmpty && $0.count <= 16 &&
                  Set($0).count == $0.count && $0.allSatisfy { (0...127).contains($0) } }),
              debounce.isFinite, (0...1).contains(debounce),
              maximumGap.isFinite, maximumGap > 0, maximumGap <= 1,
              minimumConfidence.isFinite, (0...1).contains(minimumConfidence)
        else { return nil }
        self.slots = slots
        self.debounce = debounce
        self.maximumGap = maximumGap
        self.minimumConfidence = minimumConfidence
    }

    /// Zero is neutral/mute. After any loss, neutral is required to rearm.
    /// Invalid data never advances the monotonic timestamp watermark.
    public mutating func observe(count: Int?, confidence: Double,
                                 time: Double) -> Change {
        guard time.isFinite, time >= 0,
              lastTime.map({ time > $0 }) ?? true else { return invalidate() }
        let gap = lastTime.map { time - $0 > maximumGap } ?? false
        lastTime = time
        if gap { return invalidate() }
        guard let count, (0...5).contains(count),
              confidence.isFinite, (minimumConfidence...1).contains(confidence)
        else { return invalidate() }
        if count == 0 {
            let hadSelection = selectedSlot != nil
            selectedSlot = nil
            pendingSlot = nil
            pendingSince = nil
            armed = true
            return hadSelection ? .releaseOwned : .unchanged
        }
        guard armed else { return .unchanged }
        if selectedSlot == count {
            pendingSlot = nil
            pendingSince = nil
            return .unchanged
        }
        if pendingSlot != count {
            pendingSlot = count
            pendingSince = time
        }
        guard let since = pendingSince, time - since >= debounce else {
            return .unchanged
        }
        selectedSlot = count
        pendingSlot = nil
        pendingSince = nil
        return .selected(slot: count, notes: slots[count - 1])
    }

    /// Call independently of frame delivery. Does not extend sample lifetime.
    public mutating func expire(at time: Double) -> Change {
        guard time.isFinite, time >= 0 else { return invalidate() }
        guard let lastTime else { return .unchanged }
        guard time >= lastTime, time - lastTime <= maximumGap else {
            // Permit a fresh neutral after timeout, but retain the watermark.
            return invalidate()
        }
        return .unchanged
    }

    /// Caller must release only this source's notes and pedals on this event.
    /// Emit even without a selected slot because helper voices may still exist.
    public mutating func invalidate() -> Change {
        armed = false
        selectedSlot = nil
        pendingSlot = nil
        pendingSince = nil
        return .releaseOwned
    }
}
