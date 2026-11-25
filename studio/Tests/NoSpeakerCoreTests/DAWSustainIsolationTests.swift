import Testing
@testable import NoSpeakerCore

@Test func splitDAWSustainTargetsEachSurfaceIncludingBeforeNotes() throws {
    let split = try #require(DAWSurfaceChannels(trackpad:0,magicMouse:2))
    for trackpad in [false,true] {
        for mouse in [false,true] {
            let snapshot = MIDIHelperSustainSnapshot(trackpadActive:trackpad,magicMouseActive:mouse)
            let expected = Set([trackpad ? 0 : nil,mouse ? 2 : nil].compactMap { $0 })
            #expect(split.sustainTargets(snapshot,independent:true) == expected)
            #expect(split.sustainTargets(snapshot,independent:false) == (snapshot.isActive ? Set([0,2]) : []))
        }
    }
}

@Test func independentPedalReleaseDoesNotCancelOtherSurfaceOrHelper() throws {
    let split = try #require(DAWSurfaceChannels(trackpad:0,magicMouse:2))
    var owners = LegacySustainOwners()
    let first = owners.replace(.touch,channels:split.sustainTargets(.init(trackpadActive:true),independent:true))
    #expect(first == [.init(.init(.sustain,channel:0),value:127)])
    let both = owners.replace(.touch,channels:split.sustainTargets(.init(trackpadActive:true,magicMouseActive:true),independent:true))
    #expect(both == [.init(.init(.sustain,channel:2),value:127)])
    let mouseOnly = owners.replace(.touch,channels:split.sustainTargets(.init(magicMouseActive:true),independent:true))
    #expect(mouseOnly == [.init(.init(.sustain,channel:0),value:0)])
    let helper = owners.replace(.helper,channels:[2])
    #expect(helper.isEmpty)
    let stop = owners.replace(.touch,channels:[])
    #expect(stop.isEmpty)
    #expect(owners.active == Set([2]))
    let last = owners.replace(.helper,channels:[])
    #expect(last == [.init(.init(.sustain,channel:2),value:0)])
    #expect(owners.active.isEmpty)
}

@Test func fixedSplitPedalsRemainScopedDuringRapidAlternation() throws {
    let split = try #require(DAWSurfaceChannels(trackpad:0,magicMouse:2))
    var owners = LegacySustainOwners()
    _ = owners.replace(.touchBar,channels:[5])
    for i in 0..<1000 {
        let snapshot = MIDIHelperSustainSnapshot(trackpadActive:i%2 == 0,magicMouseActive:i%2 != 0)
        let targets = split.sustainTargets(snapshot,independent:true)
        let commands = owners.replace(.touch,channels:targets)
        #expect(commands.allSatisfy { $0.destination.channel != 5 })
        #expect(owners.active == targets.union([5]))
        #expect(owners.channels(for:.touch) == targets)
    }
    _ = owners.replace(.touch,channels:[])
    #expect(owners.active == Set([5]))
}
