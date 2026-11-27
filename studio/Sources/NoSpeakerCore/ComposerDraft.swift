import Foundation

/// An explicit replacement proposal. Observed manual changes invalidate
/// pending proposals and undo history, even if the old value is later restored.
/// A host should call observe(current:) on every external editor change;
/// value comparison alone cannot detect an unobserved edit-and-revert.
public struct ComposerDraft<Value: Equatable & Sendable>: Sendable {
    public struct Proposal: Equatable, Sendable {
        public let baseline: Value
        public let candidate: Value
    }

    public private(set) var proposal: Proposal?
    private var history: [Proposal] = []
    private var observed: Value?

    public init() {}

    /// Returns whether a proposal or undo history was invalidated.
    /// Internal replacements and undos advance the observed baseline first.
    @discardableResult
    public mutating func observe(current: Value) -> Bool {
        defer { observed = current }
        guard let observed, observed != current else { return false }
        let invalidated = proposal != nil || !history.isEmpty
        proposal = nil
        history.removeAll()
        return invalidated
    }

    public mutating func preview(current: Value, candidate: Value) {
        observe(current: current)
        proposal = .init(baseline: current, candidate: candidate)
    }

    public mutating func discard() { proposal = nil }

    public func canApply(current: Value) -> Bool {
        guard let proposal else { return false }
        return proposal.baseline == current && proposal.candidate != current
    }

    public mutating func apply(current: Value) -> Value? {
        observe(current: current)
        guard let next = proposal, canApply(current: current) else {
            proposal = nil
            return nil
        }
        proposal = nil
        if history.last?.candidate != current { history.removeAll() }
        history.append(next)
        if history.count > 16 { history.removeFirst() }
        observed = next.candidate
        return next.candidate
    }

    public func canUndo(current: Value) -> Bool { history.last?.candidate == current }

    public mutating func undo(current: Value) -> Value? {
        observe(current: current)
        guard canUndo(current: current), let last = history.popLast() else { return nil }
        proposal = nil
        observed = last.baseline
        return last.baseline
    }
}


/// A composition preview belongs to both its editor value and the exact
/// generation settings. Changing settings invalidates only the preview;
/// a manual grid edit still invalidates the replacement history.
public struct ContextualComposerDraft<Value: Equatable & Sendable, Context: Equatable & Sendable>: Sendable {
    public enum Invalidation: Equatable, Sendable { case none, grid, context }
    private var draft = ComposerDraft<Value>()
    private var previewContext: Context?

    public init() {}
    public var proposal: ComposerDraft<Value>.Proposal? { draft.proposal }

    @discardableResult
    public mutating func observe(current: Value, context: Context) -> Invalidation {
        if draft.observe(current: current) {
            previewContext = nil
            return .grid
        }
        if draft.proposal != nil, previewContext != context {
            discard()
            return .context
        }
        return .none
    }

    public mutating func preview(current: Value, candidate: Value, context: Context) {
        draft.preview(current: current, candidate: candidate)
        previewContext = context
    }

    public mutating func discard() {
        draft.discard()
        previewContext = nil
    }

    public func canApply(current: Value, context: Context) -> Bool {
        previewContext == context && draft.canApply(current: current)
    }

    public mutating func apply(current: Value, context: Context) -> Value? {
        observe(current: current, context: context)
        guard canApply(current: current, context: context) else {
            discard()
            return nil
        }
        let result = draft.apply(current: current)
        previewContext = nil
        return result
    }

    public func canUndo(current: Value) -> Bool { draft.canUndo(current: current) }

    public mutating func undo(current: Value, context: Context) -> Value? {
        observe(current: current, context: context)
        let result = draft.undo(current: current)
        if draft.proposal == nil { previewContext = nil }
        return result
    }
}
