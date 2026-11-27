import Foundation

/// Pure pitch projection for a receiver explicitly configured to A4=440
/// and the specified member bend range. No member allocation or MIDI sends.
public struct OfflineTuningMemberPitch: Equatable, Sendable {
    public let inputNote: Int
    public let step: Int
    public let anchor: Int
    public let bend: Int
    public let bendRangeSemitones: Int

    static func encode(inputNote: Int, pitch: MicrotonalKeyboardTuning.Pitch,
                       bendRangeSemitones: Int) -> Self? {
        guard (0...127).contains(inputNote), (1...96).contains(bendRangeSemitones),
              pitch.frequency.isFinite, pitch.frequency > 0 else { return nil }
        let nominal = 69 + 12 * log2(pitch.frequency / 440)
        guard nominal.isFinite,
              (-Double(bendRangeSemitones)...(127 + Double(bendRangeSemitones))).contains(nominal) else { return nil }
        let anchor = min(127, max(0, Int(nominal.rounded())))
        let fraction = (nominal - Double(anchor)) / Double(bendRangeSemitones)
        guard (-1...1).contains(fraction) else { return nil }
        let delta = Int((fraction * (fraction >= 0 ? 8191 : 8192)).rounded())
        return Self(inputNote: inputNote, step: pitch.step, anchor: anchor,
                    bend: 8192 + delta, bendRangeSemitones: bendRangeSemitones)
    }
}
