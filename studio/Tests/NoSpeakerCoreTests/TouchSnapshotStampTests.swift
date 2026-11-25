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

@Test func physicalPublicationOrderSurvivesNoteMappingRevisionAndRejectsReplay() {
    var cursor = TouchPublicationCursor()
    let a = cursor.accept(.init(revision:1,sequence:10))
    let b = cursor.accept(.init(revision:2,sequence:11))
    let duplicate = cursor.accept(.init(revision:2,sequence:11))
    let late = cursor.accept(.init(revision:1,sequence:9))
    #expect(a && b && !duplicate && !late)
    cursor.reset()
    let restarted = cursor.accept(.init(revision:0,sequence:1))
    #expect(restarted)
}

@Test func physicalSurfaceCacheDoesNotTreatOtherSurfaceFrameAsRelease() {
    var raw = PhysicalSurfaceSnapshotCache<Int,Int>()
    raw.replace(0,contacts:[11])
    raw.replace(1,contacts:[22])
    #expect(raw.combined(order:[0,1]) == [11,22])
    // A musical mapping cache is reset independently.
    var mapped = PhysicalSurfaceSnapshotCache<Int,Int>()
    mapped.replace(0,contacts:[60])
    mapped.reset()
    #expect(mapped.touchingSurfaces.isEmpty)
    #expect(raw.touchingSurfaces == [0,1])
    raw.replace(0,contacts:[])
    #expect(raw.combined(order:[0,1]) == [22])
    #expect(raw.touchingSurfaces == [1])
    raw.reset()
    #expect(raw.touchingSurfaces.isEmpty)
}

@Test func rawHelperReleaseCanPassWhileObsoleteMusicalMapIsRejected() {
    var physical = TouchPublicationCursor()
    var musical = TouchSnapshotCursor()
    let down = TouchSnapshotStamp(revision:4,sequence:1)
    let up = TouchSnapshotStamp(revision:4,sequence:2)
    let rawDown = physical.accept(down)
    let noteDown = musical.accept(down,currentRevision:4)
    let rawUp = physical.accept(up)
    let oldNoteUp = musical.accept(up,currentRevision:5)
    #expect(rawDown && noteDown && rawUp && !oldNoteUp)
}

@Test func unrelatedPhysicalSurfaceCannotRefreshClickEvidence() {
    var cache = PhysicalSurfaceSnapshotCache<Int,Int>()
    let old = PhysicalSurfaceObservation(stamp:.init(revision:1,sequence:1),receivedAt:10)
    let unrelated = PhysicalSurfaceObservation(stamp:.init(revision:2,sequence:2),receivedAt:20)
    cache.replace(0,contacts:[5],observation:old)
    cache.replace(1,contacts:[],observation:unrelated)
    #expect(cache.singleTouchObservation == old)
    #expect(cache.singleTouchObservation?.stamp.revision == 1)
    #expect(cache.singleTouchObservation?.receivedAt == 10)
    cache.replace(0,contacts:[5],observation:.init(stamp:.init(revision:2,sequence:3),receivedAt:21))
    #expect(cache.singleTouchObservation?.stamp.revision == 2)
    #expect(cache.singleTouchObservation?.receivedAt == 21)
}

@Test func ambiguousPhysicalClickEvidenceFailsClosedUntilOneSurfaceRemains() {
    var cache = PhysicalSurfaceSnapshotCache<Int,Int>()
    let a = PhysicalSurfaceObservation(stamp:.init(revision:1,sequence:1),receivedAt:10)
    let b = PhysicalSurfaceObservation(stamp:.init(revision:1,sequence:2),receivedAt:11)
    cache.replace(0,contacts:[5],observation:a)
    cache.replace(1,contacts:[5],observation:b)
    #expect(cache.touchingSurfaces == [0,1])
    #expect(cache.singleTouchObservation == nil)
    cache.replace(1,contacts:[],observation:b)
    #expect(cache.singleTouchObservation == a)
    cache.replace(0,contacts:[5])
    #expect(cache.singleTouchObservation == nil)
    cache.reset()
    #expect(cache.singleTouchObservation == nil)
}

@Test func touchPublicationAdmissionPreservesExactLegacyBacklogBoundary() {
    #expect(TouchPublicationAdmission.permits(queuedAt:0,now:0))
    #expect(TouchPublicationAdmission.permits(queuedAt:0,now:0.149999))
    #expect(!TouchPublicationAdmission.permits(queuedAt:0,now:0.150))
    #expect(!TouchPublicationAdmission.permits(queuedAt:0,now:0.151))
    #expect(!TouchPublicationAdmission.permits(queuedAt:0.001,now:0))
    #expect(!TouchPublicationAdmission.permits(queuedAt:-0.001,now:0))
    #expect(!TouchPublicationAdmission.permits(queuedAt:.nan,now:0))
    #expect(!TouchPublicationAdmission.permits(queuedAt:0,now:.infinity))
}

@Test func touchPublicationMustBeRecheckedAfterEarlierFrameConsumesBudget() {
    let queued:[Double]=[0,0.01]
    #expect(queued.allSatisfy { TouchPublicationAdmission.permits(queuedAt:$0,now:0.14) })
    #expect(!TouchPublicationAdmission.permits(queuedAt:queued[1],now:0.17))
    #expect(TouchPublicationAdmission.permits(queuedAt:0.16,now:0.17))
}
