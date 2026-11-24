import Testing
@testable import NoSpeakerCore

@Test func incomingNoteCountsAndPedalDriveActualSoundingTransitions() {
    var state = LegacyIncomingNotes()
    let key = LegacyIncomingNotes.Key(channel:1,note:60)
    let off = SensorCommand(.init(.note,channel:1,number:60),value:0)
    _ = state.noteOn(channel:1,note:60,velocity:90)
    _ = state.noteOn(channel:1,note:60,velocity:100)
    #expect(state.noteOff(channel:1,note:60).isEmpty)
    #expect(state.notes[key]?.keyDownCount == 1)
    _ = state.control(channel:1,controller:64,value:127)
    #expect(state.noteOff(channel:1,note:60).isEmpty)
    #expect(state.notes[key]?.keyDownCount == 0)
    #expect(state.noteOff(channel:1,note:60).isEmpty)
    #expect(state.control(channel:1,controller:64,value:0) == [off])
    #expect(state.notes.isEmpty)
}
@Test func incomingAllNotesOffHonorsPedalWhileAllSoundOffDoesNot() {
    var state = LegacyIncomingNotes()
    _ = state.noteOn(channel:1,note:60,velocity:90)
    _ = state.noteOn(channel:1,note:62,velocity:90)
    _ = state.noteOn(channel:2,note:60,velocity:90)
    _ = state.control(channel:1,controller:64,value:127)
    #expect(state.control(channel:1,controller:123,value:0).isEmpty)
    #expect(state.notes.count == 3)
    #expect(state.control(channel:1,controller:120,value:0) == [
        .init(.init(.note,channel:1,number:60),value:0),
        .init(.init(.note,channel:1,number:62),value:0)])
    #expect(state.notes.count == 1 && state.sustained == [1])
    #expect(state.control(channel:1,controller:121,value:0).isEmpty)
    #expect(state.sustained.isEmpty)
}
@Test func incomingControllerResetReleasesOnlyUnheldNotes() {
    var state = LegacyIncomingNotes()
    _ = state.noteOn(channel:0,note:60,velocity:90)
    _ = state.noteOn(channel:0,note:62,velocity:90)
    _ = state.control(channel:0,controller:64,value:127)
    _ = state.noteOff(channel:0,note:60)
    #expect(state.control(channel:0,controller:121,value:0) == [.init(.init(.note,number:60),value:0)])
    #expect(state.notes.count == 1)
    #expect(state.noteOff(channel:0,note:62) == [.init(.init(.note,number:62),value:0)])
}
@Test func incomingBendRangeIgnoresDataEntryAfterNRPNNullAndReset() {
    var s = LegacyBendRangeState()
    s.control(101,value:0); s.control(100,value:0)
    s.control(6,value:12); s.control(38,value:50)
    #expect(s.range == 12.5)
    s.control(99,value:1); s.control(6,value:24)
    #expect(s.range == 12.5)
    s.control(101,value:0); s.control(6,value:24)
    #expect(s.range == 12.5)
    s.control(100,value:0); s.control(6,value:24)
    #expect(s.range == 24.5)
    s.control(101,value:127); s.control(100,value:127)
    s.control(38,value:0)
    #expect(s.range == 24.5)
    s.control(121,value:0); s.control(6,value:24)
    #expect(s.range == 2)
}
