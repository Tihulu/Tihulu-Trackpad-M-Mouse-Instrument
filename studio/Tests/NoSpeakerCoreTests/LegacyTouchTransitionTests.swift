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
