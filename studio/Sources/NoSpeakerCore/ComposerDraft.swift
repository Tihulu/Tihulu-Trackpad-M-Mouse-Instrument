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
