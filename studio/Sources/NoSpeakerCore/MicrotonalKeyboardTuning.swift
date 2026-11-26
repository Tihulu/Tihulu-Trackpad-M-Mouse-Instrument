import Foundation

/// Offline octave-periodic keyboard pitch model. Each degree has its own
/// identity even when two pitches share a MIDI anchor. This does not
/// authorize MIDI, MPE, remote routing or a native keyboard start.
public struct MicrotonalKeyboardTuning: Equatable, Sendable {
    public static let maximumDegrees = 128
    public static let maximumPageKeys = 25
    public struct Pitch: Equatable, Sendable {
        public let step: Int
        public let degree: Int
        public let octave: Int
        public let centsFromRoot: Double
        public let frequency: Double
    }
    public struct PageKey: Equatable, Sendable {
        public let slot: Int
        public let pitch: Pitch
    }
    public let degrees: [Double]
    public let rootMIDI: Int
    public let referenceA4: Double

    /// Degrees in ascending cents from the root, including 0, excluding
    /// the repeated 1200-cent endpoint. A4 defines the 12-TET root anchor.
    public init?(degrees: [Double], rootMIDI: Int = 60, referenceA4: Double = 440) {
        guard (2...Self.maximumDegrees).contains(degrees.count),
              degrees.first == 0,
              degrees.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1200 }),
              zip(degrees, degrees.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              (0...127).contains(rootMIDI),
              referenceA4.isFinite, (400...480).contains(referenceA4) else { return nil }
        self.degrees = degrees
        self.rootMIDI = rootMIDI
        self.referenceA4 = referenceA4
    }
    public static func edo(_ count: Int, rootMIDI: Int = 60, referenceA4: Double = 440) -> Self? {
        guard (2...maximumDegrees).contains(count) else { return nil }
        return Self(degrees: (0..<count).map { 1200 * Double($0) / Double(count) },
                    rootMIDI: rootMIDI, referenceA4: referenceA4)
    }
    /// Limit to the MIDI pitch domain for this preview; do not round away
    /// fractional pitches or claim that the receiving instrument supports them.
    public func pitch(step: Int) -> Pitch? {
        guard (-Self.maximumDegrees * 11...Self.maximumDegrees * 11).contains(step) else { return nil }
        let count = degrees.count
        let degree = ((step % count) + count) % count
        let octave = (step - degree) / count
        let cents = Double(octave) * 1200 + degrees[degree]
        let nominal = Double(rootMIDI) + cents / 100
        guard (0...127).contains(nominal) else { return nil }
        let frequency = referenceA4 * pow(2, (nominal - 69) / 12)
        guard frequency.isFinite, frequency > 0 else { return nil }
        return Pitch(step: step, degree: degree, octave: octave, centsFromRoot: cents, frequency: frequency)
    }
    /// Offline view of a page using explicit logical slots, not an implicit
    /// MIDI pitch-class map. Sparse slots stay sparse; no widening of the
    /// existing 25-bit mobile wire protocol and no live remapping.
    public func page(firstStep: Int, authorizedSlots: Int) -> [PageKey]? {
        guard authorizedSlots > 0, authorizedSlots < (1 << Self.maximumPageKeys) else { return nil }
        let slots = (0..<Self.maximumPageKeys).filter { authorizedSlots & (1 << $0) != 0 }
        var keys: [PageKey] = []
        for (index, slot) in slots.enumerated() {
            let (step, overflow) = firstStep.addingReportingOverflow(index)
            guard !overflow, let pitch = pitch(step: step) else { return nil }
            keys.append(PageKey(slot: slot, pitch: pitch))
        }
        return keys
    }
}
