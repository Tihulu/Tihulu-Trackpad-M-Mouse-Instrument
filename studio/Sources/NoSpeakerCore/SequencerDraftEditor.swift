import Foundation

/// Offline transactional editor for the next pattern only. Does not own a
/// running take, scheduler, output route, permission or live session.
/// Reuse the archive's musical equality and the existing bounded undo logic.
public struct SequencerDraftEditor: Sendable {
    public enum EditError: Error, Equatable { case wrongKind, drumChannel }

    public private(set) var draft: SequencerPatternArchive
    private var history = ComposerDraft<SequencerPatternArchive>()

    public init(draft: SequencerPatternArchive) throws {
        // An editor's current document must also be exportable.
        _ = try draft.encoded()
        self.draft = draft
    }

    public var canUndo: Bool { history.canUndo(current: draft) }

    /// A complete same-kind replacement; malformed and oversized candidates
    /// leave the original pattern and its undo history untouched.
    @discardableResult
    public mutating func replace(with candidate: SequencerPatternArchive) throws -> Bool {
        guard candidate.kind == draft.kind else { throw EditError.wrongKind }
        guard candidate != draft else { return false }
        _ = try candidate.encoded()
        history.preview(current: draft, candidate: candidate)
        guard let next = history.apply(current: draft) else { return false }
        draft = next
        return true
    }

    /// The caller must explicitly choose to replace the next draft.
    /// Decoding alone has no editor or transport side effects.
    @discardableResult
    public mutating func replaceImported(_ data: Data) throws -> Bool {
        try replace(with: SequencerPatternArchive.decode(data))
    }

    /// A batch edit is committed as one undo step only after validation.
    /// Out-of-grid cells are not silently discarded when shortening a grid.
    @discardableResult
    public mutating func editNotes(_ edit: (inout NoteSequence) throws -> Void) throws -> Bool {
        guard var notes = draft.noteDraft(), let channel = draft.channel else {
            throw EditError.wrongKind
        }
        try edit(&notes)
        return try replace(with: .init(notes: notes, channel: channel, loop: draft.loop, groove: draft.groove))
    }

    @discardableResult
    public mutating func editDrums(_ edit: (inout DrumSequence) throws -> Void) throws -> Bool {
        guard var drums = draft.drumDraft() else { throw EditError.wrongKind }
        try edit(&drums)
        return try replace(with: .init(drums: drums, loop: draft.loop, groove: draft.groove))
    }

    /// Explicit options edit; nil groove clears it. Nil channel retains
    /// the current note channel, and a drum channel override is rejected.
    @discardableResult
    public mutating func setOptions(loop: Bool, groove: GrooveSettings?, channel: Int? = nil) throws -> Bool {
        if let notes = draft.noteDraft(), let currentChannel = draft.channel {
            return try replace(with: .init(notes: notes, channel: channel ?? currentChannel,
                                           loop: loop, groove: groove))
        }
        guard channel == nil else { throw EditError.drumChannel }
        guard let drums = draft.drumDraft() else { throw EditError.wrongKind }
        return try replace(with: .init(drums: drums, loop: loop, groove: groove))
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = history.undo(current: draft) else { return false }
        draft = previous
        return true
    }

    /// Prepare a nominal snapshot on explicit request. A previously frozen
    /// value is independent of all later edits, imports, undo and clear.
    public func frozen() throws -> FrozenSequencerPattern { try draft.frozen() }
}
