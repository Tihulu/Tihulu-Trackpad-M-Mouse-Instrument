import Testing
@testable import NoSpeakerCore

@Test func standardScaleLockPreservesEveryInScaleMIDIKeyForEveryRoot() throws {
    let intervals=[0,2,4,5,7,9,11]
    for root in 0...127 {
        let map=try #require(PhysicalKeyboardScaleMap.standardLock(intervals:intervals,root:root))
        for note in 0...127 {
            let expected=intervals.contains((note-root+144)%12)
            #expect(map.key(note)?.isMapped==expected)
            if expected {
                #expect(map.memberPitch(note)?.anchor==note)
                #expect(map.memberPitch(note)?.bend==8192)
            }
        }
    }
}
@Test func standardScaleLockMuteBothEdgesAndPreserveVelocity() throws {
    var lock=try #require(PhysicalKeyboardScaleLock(intervals:[0,2,4,5,7,9,11],root:60,channel:3))
    var sent:[SensorCommand]=[]
    let sink:(SensorCommand)->Bool={sent.append($0);return true}
    #expect(lock.note(61,velocity:100,send:sink) == .muted)
    #expect(lock.note(61,velocity:0,send:sink) == .muted)
    #expect(lock.note(60,velocity:95,send:sink) == .delivered)
    #expect(lock.note(60,velocity:70,send:sink) == .ignored)
    #expect(lock.note(60,velocity:0,send:sink) == .delivered)
    #expect(lock.note(60,velocity:0,send:sink) == .ignored)
    #expect(sent == [.init(.init(.note,channel:3,number:60),value:95),.init(.init(.note,channel:3,number:60),value:0)])
}
@Test func standardScaleLockSustainAndRetainedCleanup() throws {
    var lock=try #require(PhysicalKeyboardScaleLock(intervals:[0,3,5,7,10],root:62))
    var sent:[SensorCommand]=[]
    let sink:(SensorCommand)->Bool={sent.append($0);return true}
    _=lock.sustain(64,send:sink)
    _=lock.note(62,velocity:100,send:sink)
    let failedStop=lock.stop(send:{_ in false})
    #expect(!failedStop)
    #expect(lock.pendingCleanup)
    sent.removeAll()
    let cleaned=lock.stop(send:sink)
    #expect(cleaned)
    #expect(sent == [.init(.init(.note,number:62),value:0),.init(.init(.sustain),value:0)])
    #expect(lock.note(62,velocity:90,send:sink) == .retired)
}
@Test func standardScaleLockAmbiguousSendFailureCannotRearm() throws {
    var lock=try #require(PhysicalKeyboardScaleLock(intervals:[0,2,4,7,9],root:60))
    #expect(lock.note(60,velocity:80,send:{_ in false}) == .failed)
    #expect(lock.pendingCleanup)
    let cleaned=lock.stop(send:{_ in true})
    #expect(cleaned)
    #expect(lock.note(60,velocity:80,send:{_ in true}) == .retired)
    #expect(PhysicalKeyboardScaleLock(intervals:[0,0],root:60) == nil)
    #expect(PhysicalKeyboardScaleLock(intervals:[0,2],root:60,channel:16) == nil)
}
