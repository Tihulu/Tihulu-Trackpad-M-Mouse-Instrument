import Testing
@testable import NoSpeakerCore

@Test func composerDraftPreviewDoesNotReplaceAndUndoIsOrdered() {
    var d=ComposerDraft<[Int]>()
    d.preview(current:[1],candidate:[2])
    #expect(d.canApply(current:[1]))
    let first=d.apply(current:[1])
    #expect(first == [2])
    d.preview(current:[2],candidate:[3])
    let second=d.apply(current:[2])
    #expect(second == [3])
    let undo1=d.undo(current:[3])
    #expect(undo1 == [2])
    let undo2=d.undo(current:[2])
    #expect(undo2 == [1])
}
@Test func composerDraftRejectsStaleManualEditsAndBoundsHistory() {
    var d=ComposerDraft<Int>()
    d.preview(current:0,candidate:1)
    let stale=d.apply(current:2)
    #expect(stale == nil)
    for i in 0..<20 {
        d.preview(current:i,candidate:i+1)
        let next=d.apply(current:i)
        #expect(next == i+1)
    }
    #expect(!d.canUndo(current:99))
    for i in stride(from:20,to:4,by:-1) {
        let previous=d.undo(current:i)
        #expect(previous == i-1)
    }
    #expect(!d.canUndo(current:4))
}

@Test func composerContextMismatchRejectsApplyWithoutObservation() {
    var draft = ContextualComposerDraft<[Int], String>()
    draft.preview(current: [60], candidate: [64], context: "melody")
    #expect(draft.canApply(current: [60], context: "melody"))
    #expect(!draft.canApply(current: [60], context: "bass"))
    #expect(draft.apply(current: [60], context: "bass") == nil)
    #expect(draft.proposal == nil)
    #expect(!draft.canUndo(current: [60]))
}

@Test func composerContextEditAndRevertDoesNotRevivePreviewButKeepsUndo() {
    var draft = ContextualComposerDraft<Int, Int>()
    draft.preview(current: 1, candidate: 2, context: 10)
    #expect(draft.apply(current: 1, context: 10) == 2)
    draft.preview(current: 2, candidate: 3, context: 10)
    #expect(draft.observe(current: 2, context: 11) == .context)
    #expect(draft.observe(current: 2, context: 10) == .none)
    #expect(!draft.canApply(current: 2, context: 10))
    #expect(draft.canUndo(current: 2))
    #expect(draft.undo(current: 2, context: 10) == 1)
}

@Test func composerVariationUsesNewContextBeforeDelayedUIObservation() {
    var draft = ContextualComposerDraft<Int, Int>()
    draft.preview(current: 1, candidate: 2, context: 9999)
    draft.preview(current: 1, candidate: 3, context: 1)
    #expect(draft.observe(current: 1, context: 1) == .none)
    #expect(draft.canApply(current: 1, context: 1))
    #expect(draft.apply(current: 1, context: 1) == 3)
    #expect(draft.undo(current: 3, context: 2) == 1)
}

@Test func composerContextualManualEditClearsHistoryEvenAfterRevert() {
    var draft = ContextualComposerDraft<Set<String>, String>()
    draft.preview(current: ["kick:0"], candidate: ["kick:4"], context: "rock")
    #expect(draft.apply(current: ["kick:0"], context: "rock") == ["kick:4"])
    draft.preview(current: ["kick:4"], candidate: ["kick:8"], context: "house")
    #expect(draft.observe(current: ["snare:2"], context: "funk") == .grid)
    #expect(draft.observe(current: ["kick:4"], context: "house") == .none)
    #expect(!draft.canUndo(current: ["kick:4"]))
    #expect(!draft.canApply(current: ["kick:4"], context: "house"))
}

@Test func composerContextualDiscardAndNoopDoNotDestroyExistingHistory() {
    var draft = ContextualComposerDraft<Int, Int>()
    draft.preview(current: 1, candidate: 2, context: 1)
    #expect(draft.apply(current: 1, context: 1) == 2)
    draft.preview(current: 2, candidate: 2, context: 2)
    #expect(!draft.canApply(current: 2, context: 2))
    #expect(draft.apply(current: 2, context: 2) == nil)
    draft.preview(current: 2, candidate: 3, context: 3)
    draft.discard()
    #expect(draft.proposal == nil)
    #expect(draft.undo(current: 2, context: 4) == 1)
}

@Test func composerContextualOptionalContextAndValueRemainDistinctFromAbsentProposal() {
    var draft = ContextualComposerDraft<Int?, String?>()
    #expect(!draft.canApply(current: nil, context: nil))
    draft.preview(current: nil, candidate: 5, context: nil)
    #expect(draft.canApply(current: nil, context: nil))
    #expect(!draft.canApply(current: nil, context: "new"))
    #expect(draft.apply(current: nil, context: nil) == 5)
    let undo = draft.undo(current: 5, context: "new")
    #expect(undo != nil)
    #expect(undo! == nil)
}
