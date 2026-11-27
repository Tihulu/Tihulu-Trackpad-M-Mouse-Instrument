import Foundation

/// Receiver-dependent arithmetic only. A host must independently establish
/// endpoint, zone, channel and voice ownership before any actual output.
public enum OfflineTuningExpression {
    public struct MemberProjection: Equatable, Sendable {
        public let base: OfflineTuningMemberPitch
        public let expressiveBend: Int
        public let representedOffsetCents: Double
    }
    public enum MemberResult: Equatable, Sendable {
        case projected(MemberProjection)
        case exceedsMemberRange
        case invalid
    }
    public struct ZoneProjection: Equatable, Sendable {
        public let base: OfflineTuningMemberPitch
        public let masterBend: Int
        public let masterRangeSemitones: Int
        /// Conditional on a receiver which combines master and member pitch
        /// offsets in semitone units. Not receiver feedback or measurement.
        public let predictedPitchFromAnchorCents: Double
    }

    private static func valid(_ base: OfflineTuningMemberPitch) -> Bool {
        (0...127).contains(base.inputNote) && (0...127).contains(base.anchor) &&
        (0...16383).contains(base.bend) && (1...96).contains(base.bendRangeSemitones)
    }
    private static func cents(bend: Int, range: Int) -> Double {
        let delta = Double(bend - 8192)
        return delta / (delta >= 0 ? 8191 : 8192) * Double(range) * 100
    }

    /// For an exclusively owned member only. Offset is relative to the frozen
    /// encoded base, never the last expressive value. Reject overflow instead
    /// of stealing a member, changing anchor or clipping the requested pitch.
    /// Offset zero restores the exact encoded base, not center bend.
    public static func member(base: OfflineTuningMemberPitch, offsetCents: Double) -> MemberResult {
        guard valid(base), offsetCents.isFinite else { return .invalid }
        if offsetCents == 0 {
            return .projected(.init(base: base, expressiveBend: base.bend, representedOffsetCents: 0))
        }
        let baseCents = cents(bend: base.bend, range: base.bendRangeSemitones)
        let limit = Double(base.bendRangeSemitones) * 100
        // Compare in the offset domain used by readiness headroom. A rounded
        // addition can otherwise reject the reported endpoint or hide an
        // offset immediately outside it. Only normalize the sum after admission.
        guard (-limit - baseCents...limit - baseCents).contains(offsetCents) else {
            return .exceedsMemberRange
        }
        let requested = min(limit, max(-limit, baseCents + offsetCents))
        let fraction = requested / limit
        let bend = 8192 + Int((fraction * (fraction >= 0 ? 8191 : 8192)).rounded())
        return .projected(.init(base: base, expressiveBend: bend,
            representedOffsetCents: cents(bend: bend, range: base.bendRangeSemitones) - baseCents))
    }

    /// For a separately owned zone master. Do not sum raw bend units or
    /// copy the master value into a member. The base stays unchanged.
    public static func zone(base: OfflineTuningMemberPitch, masterBend: Int,
                            masterRangeSemitones: Int) -> ZoneProjection? {
        guard valid(base), (0...16383).contains(masterBend),
              (1...96).contains(masterRangeSemitones) else { return nil }
        return .init(base: base, masterBend: masterBend, masterRangeSemitones: masterRangeSemitones,
            predictedPitchFromAnchorCents: cents(bend: base.bend, range: base.bendRangeSemitones) +
                cents(bend: masterBend, range: masterRangeSemitones))
    }
}
