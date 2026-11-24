import Testing
@testable import NoSpeakerCore

@Test func touchSnapshotCursorRejectsOldRevisionAndReorderedPublication() {
    var cursor = TouchSnapshotCursor()
    let accepted = cursor.accept(.init(revision:1,sequence:2),currentRevision:1)
    #expect(accepted)
    let older = cursor.accept(.init(revision:1,sequence:1),currentRevision:1)
    #expect(!older)
    let duplicate = cursor.accept(.init(revision:1,sequence:2),currentRevision:1)
    #expect(!duplicate)
    let old = cursor.accept(.init(revision:1,sequence:3),currentRevision:2)
    #expect(!old)
    let fresh = cursor.accept(.init(revision:2,sequence:4),currentRevision:2)
    #expect(fresh)
}
@Test func touchSnapshotCursorPreservesOrderedEdgesAcrossRevisions() {
    var cursor = TouchSnapshotCursor()
    for i in UInt64(1)...100 {
        let accepted = cursor.accept(.init(revision:1,sequence:i),currentRevision:1)
        #expect(accepted)
    }
    cursor.reset()
    let restart = cursor.accept(.init(revision:0,sequence:1),currentRevision:0)
    #expect(restart)
}
