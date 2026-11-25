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

@Test func helperPublicationFenceDoesNotDropIndependentTouchEdges() {
    var cursor = TouchSnapshotCursor()
    var helper = TouchConsumerPublicationFence()
    helper.begin(after:2)
    let down = TouchSnapshotStamp(revision:1,sequence:1)
    let up = TouchSnapshotStamp(revision:1,sequence:2)
    let next = TouchSnapshotStamp(revision:1,sequence:3)
    let downAccepted = cursor.accept(down,currentRevision:1)
    let upAccepted = cursor.accept(up,currentRevision:1)
    #expect(downAccepted && upAccepted)
    #expect(!helper.permits(down,selectedSource:true))
    #expect(!helper.permits(up,selectedSource:true))
    #expect(helper.permits(next,selectedSource:true))
}

@Test func effectsOnlyFenceLeavesExistingPedalPublicationUntouched() {
    var pedal = TouchConsumerPublicationFence()
    var effects = TouchConsumerPublicationFence()
    pedal.begin(after:1)
    effects.begin(after:4)
    let queuedRelease = TouchSnapshotStamp(revision:3,sequence:4)
    #expect(pedal.permits(queuedRelease,selectedSource:true))
    #expect(!effects.permits(queuedRelease,selectedSource:true))
    let newer = TouchSnapshotStamp(revision:3,sequence:5)
    #expect(effects.permits(newer,selectedSource:true))
}

@Test func helperFenceRequiresActualSelectedSurfaceAndSurvivesMappingRevision() {
    var fence = TouchConsumerPublicationFence()
    fence.begin(after:10)
    #expect(!fence.permits(.init(revision:9,sequence:10),selectedSource:true))
    #expect(!fence.permits(.init(revision:10,sequence:11),selectedSource:false))
    #expect(fence.permits(.init(revision:10,sequence:11),selectedSource:true))
    fence.reset()
    #expect(fence.permits(.init(revision:0,sequence:1),selectedSource:true))
}
