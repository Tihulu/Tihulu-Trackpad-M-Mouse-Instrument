import Testing
@testable import NoSpeakerCore

private func n(_ channel:Int,_ note:Int,_ value:Int) -> SensorCommand {
    .init(.init(.note,channel:channel,number:note),value:value)
}
@Test func legacyNotesPreserveSharedTouchAndPerformanceOwners() {
    var s = LegacyNoteOwners<String>()
    #expect(s.press("finger1",channel:0,note:60,velocity:80) == [n(0,60,80)])
    #expect(s.press("finger2",channel:0,note:60,velocity:110).isEmpty)
    #expect(s.press("screen",channel:0,note:60,velocity:95).isEmpty)
    #expect(s.release("finger1").isEmpty)
    #expect(s.press("finger2",channel:0,note:62,velocity:100) == [n(0,62,100)])
    #expect(s.release("screen") == [n(0,60,0)])
    #expect(s.release("screen").isEmpty)
    #expect(s.releaseAll() == [n(0,62,0)])
}
@Test func legacyNotesSeparateChannelsAndRejectInvalidWithoutMutation() {
    var s = LegacyNoteOwners<Int>()
    #expect(s.press(1,channel:1,note:60,velocity:90) == [n(1,60,90)])
    #expect(s.press(2,channel:2,note:60,velocity:90) == [n(2,60,90)])
    #expect(s.press(1,channel:1,note:60,velocity:110).isEmpty)
    #expect(s.press(1,channel:16,note:60,velocity:100).isEmpty)
    #expect(s.press(1,channel:1,note:60,velocity:0).isEmpty)
    #expect(s.press(1,channel:2,note:60,velocity:100) == [n(1,60,0)])
    #expect(s.releaseAll() == [n(2,60,0)])
    #expect(s.active.isEmpty)
}
