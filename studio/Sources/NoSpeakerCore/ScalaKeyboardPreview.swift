/// Frozen, read-only projection of an imported scale and keyboard map.
/// In particular, an assigned but unrepresentable pitch cannot become an
/// original-note bypass. Native routing and unlock policy are not included.
public struct ScalaKeyboardPreview: Equatable, Sendable {
    public enum Output: Equatable, Sendable {
        case tuned(MicrotonalKeyboardTuning.Pitch)
        case unmapped
        case outsideRange
        case unavailable
    }
    public let mapping: ScalaKeyboardImport.Mapping
    public let tuning: MicrotonalKeyboardTuning

    public init(scale: ScalaKeyboardImport.Scale, mapping: ScalaKeyboardImport.Mapping) throws {
        self.tuning = try ScalaKeyboardImport.tuning(scale: scale, mapping: mapping)
        self.mapping = mapping
    }
    public func output(_ note: Int) -> Output {
        guard (0...127).contains(note) else { return .unavailable }
        guard (mapping.first...mapping.last).contains(note) else { return .outsideRange }
        guard let step = mapping.step(note) else { return .unmapped }
        guard let pitch = tuning.pitch(step: step) else { return .unavailable }
        return .tuned(pitch)
    }

    /// Receiver-dependent offline projection only. Unlike the legacy
    /// explicitly unlocked map, imported holes never emit original notes.
    public enum MemberOutput: Equatable, Sendable {
        case tuned(OfflineTuningMemberPitch)
        case unmapped
        case outsideRange
        case unavailable
    }
    public func memberOutput(_ note: Int, bendRangeSemitones: Int = 2) -> MemberOutput {
        guard (1...96).contains(bendRangeSemitones) else { return .unavailable }
        switch output(note) {
        case .tuned(let pitch):
            guard let member = OfflineTuningMemberPitch.encode(inputNote: note, pitch: pitch,
                  bendRangeSemitones: bendRangeSemitones) else { return .unavailable }
            return .tuned(member)
        case .unmapped: return .unmapped
        case .outsideRange: return .outsideRange
        case .unavailable: return .unavailable
        }
    }
}
