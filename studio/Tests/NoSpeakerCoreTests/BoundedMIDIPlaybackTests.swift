import Testing
@testable import NoSpeakerCore

private func playbackClip() -> MIDIClip {
    .init(bpm:120,length:1920,notes:[
        .init(start:0,duration:480,channel:0,pitch:60,velocity:90),
        .init(start:480,duration:480,channel:0,pitch:60,velocity:100),
        .init(start:0,duration:960,channel:1,pitch:64,velocity:80)
    ])
}

@Test func boundedPlaybackOrdersRetriggerAndPreservesTrailingRest() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    let started=try player.begin(now:100)
    #expect(started)
    var commands:[SensorCommand]=[]
    player.advance(now:100){ commands.append($0);return true }
    #expect(commands.map(\.value)==[90,80])
    #expect(player.nextDeadline==250_000_100)
    player.advance(now:250_000_100){ commands.append($0);return true }
    #expect(commands.map(\.value)==[90,80,0,100])
    player.advance(now:500_000_100){ commands.append($0);return true }
    #expect(player.outstanding.isEmpty)
    #expect(player.state == .playing)
    #expect(player.nextDeadline==1_000_000_100)
    player.advance(now:1_000_000_100){ commands.append($0);return true }
    #expect(player.state == .finished)
    #expect(commands.count==6)
    let restarted=try player.begin(now:1_000_000_200)
    #expect(!restarted)
}

@Test func boundedPlaybackRejectsLateOnsetsAndRetiresExistingNotes() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var commands:[SensorCommand]=[]
    player.advance(now:0){ commands.append($0);return true }
    player.advance(now:310_000_000){ commands.append($0);return true }
    #expect(player.state == .faulted)
    #expect(commands.map(\.value)==[90,80,0,0])
    #expect(player.outstanding.isEmpty)
    player.advance(now:500_000_000){ commands.append($0);return true }
    #expect(commands.count==4)
}

@Test func boundedPlaybackDoesNotCollapseShortNoteIntoSamePoll() throws {
    let clip=MIDIClip(bpm:120,length:960,notes:[.init(start:0,duration:1,channel:0,pitch:60,velocity:90)])
    var player=try BoundedMIDIPlayback(clip:clip)
    _=try player.begin(now:0)
    var commands:[SensorCommand]=[]
    player.advance(now:1_000_000){ commands.append($0);return true }
    #expect(player.state == .faulted)
    #expect(commands.isEmpty)
}

@Test func boundedPlaybackTracksAmbiguousOnsetAndRetriesOnlyDebt() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var commands:[SensorCommand]=[]
    player.advance(now:0){ commands.append($0);return false }
    #expect(player.state == .faulted)
    #expect(commands.map(\.value)==[90,0])
    #expect(player.outstanding.count==1)
    player.retryCleanup{ commands.append($0);return true }
    #expect(commands.map(\.value)==[90,0,0])
    #expect(player.outstanding.isEmpty)
    player.retryCleanup{ commands.append($0);return true }
    #expect(commands.count==3)
}

@Test func boundedPlaybackStopAndBackwardClockReleaseOnlyOwnedNotes() throws {
    for backwards in [false,true] {
        var player=try BoundedMIDIPlayback(clip:playbackClip())
        _=try player.begin(now:100)
        var commands:[SensorCommand]=[]
        player.advance(now:100){ commands.append($0);return true }
        if backwards {
            player.advance(now:99){ commands.append($0);return true }
        } else {
            player.stop{ commands.append($0);return true }
        }
        #expect(player.state == (backwards ? .faulted : .stopped))
        #expect(commands.map(\.value)==[90,80,0,0])
        #expect(player.outstanding.isEmpty)
    }
}

@Test func boundedPlaybackRejectsExcessDurationAndClockOverflow() throws {
    var clip=playbackClip()
    clip.length=19201
    #expect(throws:BoundedMIDIPlayback.Failure.capacity) {
        _=try BoundedMIDIPlayback(clip:clip)
    }
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    #expect(throws:BoundedMIDIPlayback.Failure.clockOverflow) {
        _=try player.begin(now:UInt64.max)
    }
    #expect(player.state == .faulted)
}
