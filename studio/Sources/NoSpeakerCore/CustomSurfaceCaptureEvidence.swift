import Foundation

/// Bounded aggregate physical callback evidence. No coordinates, contact IDs,
/// absolute timestamps, raw device identifiers or key events are retained.
public struct CustomSurfaceCaptureEvidence: Equatable, Sendable {
    public private(set) var frames = 0
    public private(set) var invalidFrames = 0
    public private(set) var incompleteFrames = 0
    public private(set) var neutralFrames = 0
    public private(set) var occupiedFrames = 0
    public private(set) var maximumGapNS: Int64 = 0
    public private(set) var maximumOccupiedGapNS: Int64 = 0
    public private(set) var occupiedDeadlineGaps = 0
    public private(set) var unorderedReceipts = 0
    public private(set) var stateCounts = Array(repeating: 0, count: 17)
    private var previousReceipt: Int64?
    private var previousOccupied = false
    public init() {}
    private static func bump(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }
    /// nil occupied means the strict adapter could not classify the frame.
    public mutating func observe(receipt: Int64?, rawCount: Int?, rawStates: [Int],
                                 decodedCount: Int, occupied: Bool?) {
        Self.bump(&frames)
        if occupied == nil { Self.bump(&invalidFrames) }
        if rawCount != decodedCount { Self.bump(&incompleteFrames) }
        if occupied == true { Self.bump(&occupiedFrames) }
        if occupied == false { Self.bump(&neutralFrames) }
        for state in rawStates.prefix(NativeTouchFramePolicy.maximumContacts) {
            let bucket = (0...15).contains(state) ? state : 16
            Self.bump(&stateCounts[bucket])
        }
        guard let receipt, receipt >= 0 else { return }
        if let previousReceipt {
            guard receipt > previousReceipt else { Self.bump(&unorderedReceipts); return }
            let gap = receipt - previousReceipt
            maximumGapNS = max(maximumGapNS, gap)
            if previousOccupied {
                maximumOccupiedGapNS = max(maximumOccupiedGapNS, gap)
                if gap >= MobileAirSendGate.freshNS { Self.bump(&occupiedDeadlineGaps) }
            }
        }
        previousReceipt = receipt
        previousOccupied = occupied == true
    }
    /// Relative cadence only; this is callback evidence, not MIDI delivery.
    public var report: String {
        let states = stateCounts.enumerated().filter { $0.element > 0 }.map {
            ($0.offset == 16 ? "other" : String($0.offset)) + "=" + String($0.element)
        }.joined(separator: ", ")
        return """
        Native callback evidence (not DAW acceptance)
        Frames: \(frames) · neutral: \(neutralFrames) · occupied: \(occupiedFrames)
        Invalid: \(invalidFrames) · incomplete: \(incompleteFrames) · unordered: \(unorderedReceipts)
        Max inter-frame gap: \(maximumGapNS / 1_000_000) ms
        Max gap after occupied frame: \(maximumOccupiedGapNS / 1_000_000) ms
        Occupied gaps >= 150 ms: \(occupiedDeadlineGaps)
        Raw state record counts: \(states.isEmpty ? "none" : states)
        """
    }
}
