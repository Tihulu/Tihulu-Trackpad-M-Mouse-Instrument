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
