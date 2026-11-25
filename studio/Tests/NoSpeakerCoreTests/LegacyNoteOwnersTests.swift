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

@Test func sharedNoteGateReferenceCountsMatchScanOracleDuringRapidMixedPlaying() {
    var actual = LegacyNoteOwners<Int>()
    var expected: [Int:SensorDestination] = [:]
    var seed: UInt64 = 0x544948554c55
    func random(_ upper: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(upper))
    }
    func release(_ owner:Int) -> [SensorCommand] {
        guard let old = expected.removeValue(forKey:owner), !expected.values.contains(old) else { return [] }
        return [.init(old,value:0)]
    }
    for step in 0..<10_000 {
        let owner = random(64), channel = random(4), note = 60 + random(8), velocity = 1 + random(127)
        let op = random(12)
        var wanted: [SensorCommand] = []
        let got: [SensorCommand]
        if op == 0 {
            wanted = Set(expected.values).sorted {
                $0.channel == $1.channel ? $0.number < $1.number : $0.channel < $1.channel
            }.map { .init($0,value:0) }
            expected.removeAll()
            got = actual.releaseAll()
        } else if op < 5 {
            wanted = release(owner)
            got = actual.release(owner)
        } else if op == 5 {
            got = actual.press(owner,channel:16,note:note,velocity:velocity)
        } else {
            let target = SensorDestination(.note,channel:channel,number:note)
            if expected[owner] != target {
                wanted = release(owner)
                if !expected.values.contains(target) { wanted.append(.init(target,value:velocity)) }
                expected[owner] = target
            }
            got = actual.press(owner,channel:channel,note:note,velocity:velocity)
        }
        #expect(got == wanted, "operation \(step)")
        #expect(actual.active == Set(expected.values))
    }
    let cleanup = actual.releaseAll()
    #expect(cleanup.count == Set(expected.values).count)
    #expect(actual.active.isEmpty)
}
