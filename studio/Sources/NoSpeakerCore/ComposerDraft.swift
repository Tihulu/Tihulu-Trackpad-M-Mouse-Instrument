import Foundation

/// An explicit replacement proposal. Manual changes invalidate pending
/// proposals or undo history rather than overwriting newer edits.
public struct ComposerDraft<Value:Equatable & Sendable>:Sendable {
    public struct Proposal:Equatable,Sendable {
        public let baseline:Value
        public let candidate:Value
    }
    public private(set) var proposal:Proposal?
    private var history:[Proposal]=[]
    public init(){}
    public mutating func preview(current:Value,candidate:Value) {
        proposal = .init(baseline:current,candidate:candidate)
    }
    public mutating func discard(){proposal=nil}
    public func canApply(current:Value)->Bool {
        guard let proposal else{return false}
        return proposal.baseline==current && proposal.candidate != current
    }
    public mutating func apply(current:Value)->Value? {
        guard let next=proposal,canApply(current:current) else{proposal=nil;return nil}
        proposal=nil
        if history.last?.candidate != current {history.removeAll()}
        history.append(next)
        if history.count>16 {history.removeFirst()}
        return next.candidate
    }
    public func canUndo(current:Value)->Bool {history.last?.candidate==current}
    public mutating func undo(current:Value)->Value? {
        guard canUndo(current:current),let last=history.popLast() else{return nil}
        proposal=nil
        return last.baseline
    }
}
