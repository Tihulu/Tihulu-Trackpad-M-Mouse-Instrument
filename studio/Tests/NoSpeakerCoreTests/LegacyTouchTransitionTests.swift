import Testing
@testable import NoSpeakerCore

@Test func mpeHeldContactNoteChangeUnderPedalRequiresFreshMember() {
    #expect(LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:false,oldMPE:true,
        oldChannel:1,newNote:62,newFretless:false,newMPE:true,standardChannel:0,sustained:true))
    #expect(!LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:false,oldMPE:true,
        oldChannel:1,newNote:62,newFretless:false,newMPE:true,standardChannel:0,sustained:false))
    var pool = LegacyMPEChannelPool()
    _ = pool.retire(channel:1,sustained:true,fretless:false)
    #expect(pool.next(occupied:[],sustained:[1]) == 2)
}
@Test func touchRouteChangeCannotRetainPreviousChannelOrMode() {
    #expect(LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:false,oldMPE:false,
        oldChannel:0,newNote:36,newFretless:false,newMPE:false,standardChannel:9,sustained:false))
    #expect(LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:false,oldMPE:true,
        oldChannel:1,newNote:60,newFretless:false,newMPE:false,standardChannel:0,sustained:false))
    #expect(LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:true,oldMPE:true,
        oldChannel:1,newNote:60,newFretless:false,newMPE:true,standardChannel:0,sustained:true))
    #expect(!LegacyTouchTransition.requiresNewVoice(oldNote:60,oldFretless:true,oldMPE:true,
        oldChannel:1,newNote:60,newFretless:true,newMPE:true,standardChannel:0,sustained:true))
}

@Test func singleTouchSelectionKeepsHeldContactAcrossFrameOrdering() {
    #expect(LegacyTouchAdmission.preferredIndex(keys:[1,2],held:Set([1])) == 0)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[2,1],held:Set([1])) == 1)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[3,2,1],held:Set([1])) == 2)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[3,2],held:Set([1])) == 0)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[Int](),held:Set([1])) == nil)
}

@Test func singleTouchIdentityIncludesSurfaceAndContact() {
    struct Key:Hashable { let surface:Int; let contact:Int }
    let pad = Key(surface:0,contact:7)
    let mouse = Key(surface:1,contact:7)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[mouse,pad],held:Set([pad])) == 1)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[pad,mouse],held:Set([mouse])) == 1)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[mouse],held:Set([pad])) == 0)
}

@Test func singleTouchSelectionHandlesDuplicateFramesWithoutChangingOwner() {
    #expect(LegacyTouchAdmission.preferredIndex(keys:[2,1,1],held:Set([1])) == 1)
    #expect(LegacyTouchAdmission.preferredIndex(keys:[2,1,1],held:Set<Int>()) == 0)
}
