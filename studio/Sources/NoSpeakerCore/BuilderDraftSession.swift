/// In-memory draft only. Never persists or starts a runtime.
public struct BuilderDraftSession: Sendable {
    private var savedBaseline: InstrumentPatch?
    private var pending: InstrumentPatch?
    public init() {}

    public mutating func remember(_ draft: InstrumentPatch, saved: InstrumentPatch) {
        if draft == saved { clear(); return }
        savedBaseline = saved
        pending = draft
    }

    /// A changed saved instrument invalidates the old session draft instead
    /// of silently applying it over a newer saved patch.
    public mutating func resume(saved: InstrumentPatch) -> InstrumentPatch {
        guard savedBaseline == saved, let pending else { clear(); return saved }
        return pending
    }

    public mutating func clear() { savedBaseline = nil; pending = nil }
}
