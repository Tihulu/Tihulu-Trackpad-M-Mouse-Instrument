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
}
