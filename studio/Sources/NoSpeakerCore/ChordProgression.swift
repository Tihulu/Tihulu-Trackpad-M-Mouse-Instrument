import Foundation

/// Slot references intentionally follow the current chord bank, including
/// custom overrides. The bank is resolved once at the start of performance.
public struct ChordProgression: Codable, Equatable, Sendable {
    public var slots: [Int?] = [0, 4, 5, 3]
    public var beatsPerStep = 4
    public var gatePercent = 90
    public var loop = true
    public init() {}

    public var isValid: Bool {
        (1...16).contains(slots.count) &&
        slots.allSatisfy { $0.map { (0..<ChordBank.padCount).contains($0) } ?? true } &&
        [1,2,4].contains(beatsPerStep) && (10...100).contains(gatePercent)
    }

    public func plan(bank: ChordBank, bpm: Double) -> ChordProgressionPlan? {
        guard isValid, bank.isValid, bpm.isFinite, (20...300).contains(bpm),
              slots.contains(where: { $0 != nil }),
              let duration = PlaybackTimeline.patternDuration(bpm: bpm, stepsPerBeat: 1,
                                                               length: slots.count * beatsPerStep)
        else { return nil }
        let stepDuration = 60 / bpm * Double(beatsPerStep)
        var steps: [ChordProgressionPlan.Step] = []
        for (index, slot) in slots.enumerated() {
            let pad = slot.flatMap { bank.pad(at: $0) }
            if slot != nil && pad == nil { return nil }
            steps.append(.init(slot: slot, pad: pad, onset: Double(index) * stepDuration,
                               gate: stepDuration * Double(gatePercent) / 100))
        }
        return .init(steps: steps, duration: duration, channel: bank.channel - 1,
                     velocity: bank.velocity, loop: loop)
    }
}

public struct ChordProgressionPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let slot: Int?
        public let pad: ChordPad?
        public let onset: Double
        public let gate: Double
    }
    public let steps: [Step]
    public let duration: Double
    public let channel: Int
    public let velocity: Int
    public let loop: Bool
}
