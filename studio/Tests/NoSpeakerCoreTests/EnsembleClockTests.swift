import Testing
@testable import NoSpeakerCore

@Test func ensembleClockAbsoluteDeadlinesAndMeter() throws {
    var clock = try #require(EnsembleClock(bpm:120,beatsPerBar:3,now:0))
    var beats:[Int] = []
    let interval = clock.interval
    for i in 1...97 {
        let time = Double(i)*interval
        if case .wait(let delay) = clock.tick(now:time-0.001) { #expect(delay > 0 && delay < 0.002) }
        else { Issue.record("Expected wait") }
        if case .pulse(let beat) = clock.tick(now:time+0.001) { if let beat { beats.append(beat) } }
        else { Issue.record("Expected pulse") }
    }
    #expect(beats == [1,2,3,1,2])
}

@Test func ensembleClockNeverBurstsOrRearmsAfterMiss() throws {
    var clock = try #require(EnsembleClock(bpm:120,beatsPerBar:4,now:10))
    #expect(clock.tick(now:10.022) == .pulse(beat:1))
    #expect(clock.tick(now:10.2) == .fault)
    #expect(clock.tick(now:10.21) == .fault)
    var backwards = try #require(EnsembleClock(bpm:120,beatsPerBar:4,now:10))
    #expect(backwards.tick(now:9) == .fault)
    #expect(EnsembleClock(bpm:.nan,beatsPerBar:4,now:0) == nil)
    #expect(EnsembleClock(bpm:120,beatsPerBar:0,now:0) == nil)
    #expect(EnsembleClock(bpm:120,beatsPerBar:4,now:.infinity) == nil)
    #expect(EnsembleClock.Message.clock.rawValue == 0xF8)
}
