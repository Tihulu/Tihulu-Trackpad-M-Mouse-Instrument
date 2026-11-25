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

@Test func boundedPlaybackResamplesClockAfterEverySend() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var now:UInt64=0
    var commands:[SensorCommand]=[]
    player.advance(now:now,refreshNow:{ now }) { command in
        commands.append(command)
        if command.value>0 { now=51_000_000 }
        return true
    }
    #expect(player.state == .faulted)
    #expect(commands.map(\.value)==[90,0])
    #expect(player.outstanding.isEmpty)
}

@Test func boundedPlaybackCancellationDoesNotAdmitUnattemptedSecondNote() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var cancelled=false
    var commands:[SensorCommand]=[]
    player.advance(now:0,refreshNow:{0},shouldStop:{cancelled}) { command in
        commands.append(command)
        if command.value>0 { cancelled=true }
        return true
    }
    #expect(player.state == .stopped)
    #expect(commands.map(\.value)==[90,0])
    #expect(commands[0].destination==commands[1].destination)
    #expect(player.outstanding.isEmpty)
    player.advance(now:100_000_000){ commands.append($0);return true }
    #expect(commands.count==2)
}

@Test func boundedPlaybackCancellationBeforeFirstEdgeSendsNothing() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var commands:[SensorCommand]=[]
    player.advance(now:0,refreshNow:{0},shouldStop:{true}) { commands.append($0);return true }
    #expect(player.state == .stopped)
    #expect(commands.isEmpty && player.outstanding.isEmpty)
}

@Test func boundedPlaybackExternalFaultPreservesOnlyOutstandingCleanup() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var sent:[SensorCommand]=[]
    player.advance(now:0){sent.append($0);return true}
    player.abort{sent.append($0);return false}
    #expect(player.state == .faulted)
    #expect(sent.map(\.value)==[90,80,0,0])
    #expect(player.outstanding.count==2)
    player.retryCleanup{sent.append($0);return true}
    #expect(player.outstanding.isEmpty)
    #expect(sent.map(\.value)==[90,80,0,0,0,0])
    #expect(try !player.begin(now:1))
}

@Test func boundedPlaybackExternalFaultBeforeStartSendsNothing() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    player.abort{_ in Issue.record("Unexpected send before start");return false}
    #expect(player.state == .faulted && player.outstanding.isEmpty)
    #expect(try !player.begin(now:0))
}

@Test func boundedPlaybackIndexedOffRejectsExpiredRetriggerButKeepsFirstGate() throws {
    let clip=MIDIClip(bpm:120,length:960,notes:[
        .init(start:0,duration:96,channel:0,pitch:60,velocity:90),
        .init(start:96,duration:1,channel:0,pitch:60,velocity:100),
        .init(start:0,duration:960,channel:1,pitch:60,velocity:80)
    ])
    var player=try BoundedMIDIPlayback(clip:clip)
    _=try player.begin(now:0)
    var commands:[SensorCommand]=[]
    player.advance(now:0){commands.append($0);return true}
    player.advance(now:51_000_000){commands.append($0);return true}
    #expect(player.state == .faulted)
    #expect(commands.map(\.value)==[90,80,0,0])
    #expect(commands[2].destination.channel==0 && commands[3].destination.channel==1)
    #expect(player.outstanding.isEmpty)
}

@Test func boundedPlaybackTerminalInvalidationIsOneShotAndRetainsDebt() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    player.advance(now:0){_ in true}
    player.stop{_ in false}
    let debt=player.outstanding
    #expect(player.state == .stopped && debt.count==2)
    player.invalidateTerminalResult()
    #expect(player.state == .faulted && player.outstanding==debt)
    let restarted=try player.begin(now:1)
    #expect(!restarted)
    player.retryCleanup{_ in true}
    #expect(player.state == .faulted && player.outstanding.isEmpty)
}

@Test func boundedPlaybackMaximumPolyphonyReleasesEveryOwnedNoteAndNoOthers() throws {
    let notes=(0..<256).map {
        MIDIClip.Note(start:0,duration:480,channel:$0/128,pitch:$0%128,velocity:90)
    }
    var player=try BoundedMIDIPlayback(clip:.init(bpm:120,length:19200,notes:notes))
    _=try player.begin(now:0)
    var on:[SensorDestination]=[],off:[SensorDestination]=[]
    player.advance(now:0){ command in
        on.append(command.destination);return true
    }
    #expect(on.count==256 && Set(on).count==256 && player.outstanding==Set(on))
    player.advance(now:250_000_000){ command in
        off.append(command.destination);return command.destination.number%2==0
    }
    // The first ambiguous off aborts playback and attempts all remaining
    // owned offs. A subsequent retry must send only the unpaid debt.
    #expect(player.state == .faulted && !player.outstanding.isEmpty)
    #expect(Set(off).isSubset(of:Set(on)))
    let debt=player.outstanding
    var retried:[SensorDestination]=[]
    player.retryCleanup { command in
        retried.append(command.destination);return true
    }
    #expect(Set(retried)==debt && retried.count==debt.count)
    #expect(player.outstanding.isEmpty)
    player.advance(now:10_000_000_000){ _ in Issue.record("Faulted session emitted another edge");return false }
}

@Test func boundedSimulationChecksRetriggerPolyphonyAndTrailingRest() throws {
    let schedule=try BoundedMIDIPlayback(clip:playbackClip())
    let report=try BoundedMIDISimulation.run(schedule)
    #expect(report.noteOns==3 && report.noteOffs==3)
    #expect(report.peakConcurrentNotes==2 && report.durationNS==1_000_000_000)
    #expect(report.completed && report.outstandingNotes==0 && !report.hardware && !report.receiverConfirmed)
    #expect(schedule.state == .ready)
}

@Test func boundedSimulationRefusesPreviouslyStartedOrStoppedSchedule() throws {
    var schedule=try BoundedMIDIPlayback(clip:playbackClip())
    _=try schedule.begin(now:0)
    #expect(throws:BoundedMIDISimulation.Failure.self) { _=try BoundedMIDISimulation.run(schedule) }
    schedule.stop{_ in true}
    #expect(throws:BoundedMIDISimulation.Failure.self) { _=try BoundedMIDISimulation.run(schedule) }
}

@Test func boundedSimulationChecksMaximumPolyphony() throws {
    let notes=(0..<256).map {
        MIDIClip.Note(start:0,duration:480,channel:$0/128,pitch:$0%128,velocity:90)
    }
    let report=try BoundedMIDISimulation.run(BoundedMIDIPlayback(clip:.init(bpm:120,length:19200,notes:notes)))
    #expect(report.noteOns==256 && report.noteOffs==256 && report.peakConcurrentNotes==256)
    #expect(report.outstandingNotes==0 && report.durationNS==10_000_000_000 && report.completed)
}
