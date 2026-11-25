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

@Test func boundedPlaybackCancellationAtEveryEdgeNeverEmitsUnadmittedOnset() throws {
    let plan=try BoundedMIDIPlayback(clip:playbackClip())
    for cutoff in 0...plan.events.count {
        var player=plan
        _=try player.begin(now:0)
        var attempted=0,valid=true
        var sounding:Set<SensorDestination>=[]
        var ons:[SensorCommand]=[]
        while let deadline=player.nextDeadline {
            player.advance(now:deadline,refreshNow:{deadline},shouldStop:{attempted>=cutoff}) { command in
                if attempted<cutoff { attempted+=1 }
                if command.value>0 {
                    valid = sounding.insert(command.destination).inserted && valid
                    ons.append(command)
                } else {
                    valid = (sounding.remove(command.destination) != nil) && valid
                }
                return true
            }
        }
        let expected=plan.events.prefix(cutoff).map(\.command).filter{$0.value>0}
        #expect(ons==expected && valid)
        #expect(player.state == .stopped && sounding.isEmpty && player.outstanding.isEmpty)
        #expect(attempted==cutoff)
    }
}

@Test func boundedPlaybackAmbiguousFailureAtEveryEdgePreservesOnlyOwnedCleanupDebt() throws {
    let plan=try BoundedMIDIPlayback(clip:playbackClip())
    for edge in plan.events.indices {
        for delivered in [false,true] {
            var player=plan
            _=try player.begin(now:0)
            var attempted=0,failed=false
            var sounding:Set<SensorDestination>=[]
            var admitted:Set<SensorDestination>=[]
            var ons:[SensorCommand]=[]
            var cleanup:[SensorCommand]=[]
            func receive(_ command:SensorCommand) {
                if command.value>0 { sounding.insert(command.destination) }
                else { sounding.remove(command.destination) }
            }
            while let deadline=player.nextDeadline {
                player.advance(now:deadline) { command in
                    if failed {
                        cleanup.append(command)
                        return false
                    }
                    if command.value>0 { admitted.insert(command.destination);ons.append(command) }
                    if attempted==edge {
                        failed=true
                        if delivered { receive(command) }
                        return false
                    }
                    attempted+=1
                    receive(command)
                    return true
                }
            }
            #expect(failed && player.state == .faulted)
            #expect(ons==plan.events.prefix(edge+1).map(\.command).filter{$0.value>0})
            #expect(cleanup.allSatisfy{$0.value==0 && admitted.contains($0.destination)})
            let debt=player.outstanding
            #expect(sounding.isSubset(of:debt))
            var retries:Set<SensorDestination>=[]
            player.retryCleanup { command in
                #expect(command.value==0 && debt.contains(command.destination))
                retries.insert(command.destination)
                receive(command)
                return true
            }
            #expect(retries==debt && player.outstanding.isEmpty && sounding.isEmpty)
        }
    }
}

@Test func boundedPlaybackFaultDiagnosticsDistinguishLateEdgeFromSendAndClockFailure() throws {
    let plan=try BoundedMIDIPlayback(clip:playbackClip())
    for scenario in 0..<3 {
        var player=plan
        _=try player.begin(now:100)
        var commands:[SensorCommand]=[]
        if scenario==0 {
            player.advance(now:50_000_101){commands.append($0);return true}
            #expect(player.fault == .lateEvent && player.maximumObservedLatenessNS==50_000_001)
            #expect(commands.isEmpty)
        } else if scenario==1 {
            player.advance(now:100){commands.append($0);return false}
            #expect(player.fault == .sendFailed && player.maximumObservedLatenessNS==0)
            #expect(!player.outstanding.isEmpty)
        } else {
            player.advance(now:99){commands.append($0);return true}
            #expect(player.fault == .clockRegression && commands.isEmpty)
        }
        #expect(player.state == .faulted)
        let fault=player.fault
        player.retryCleanup{_ in true}
        #expect(player.outstanding.isEmpty && player.fault==fault)
    }
}

@Test func boundedPlaybackLatenessBoundaryRemainsExactlyFiftyMilliseconds() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    player.advance(now:50_000_000){_ in true}
    #expect(player.state == .playing && player.fault==nil)
    #expect(player.maximumObservedLatenessNS==50_000_000)
    player.advance(now:300_000_001){_ in true}
    #expect(player.state == .faulted && player.fault == .lateEvent)
    #expect(player.maximumObservedLatenessNS==50_000_001 && player.outstanding.isEmpty)
}

@Test func boundedPlaybackResamplesClockAfterSlowOnsetAuthorization() throws {
    let plan=try BoundedMIDIPlayback(clip:playbackClip())
    for scenario in 0..<4 {
        var player=plan
        _=try player.begin(now:100)
        var now:UInt64=100
        var stop=false
        var sent:[SensorCommand]=[]
        player.advance(now:now,refreshNow:{now},shouldStop:{stop},authorizeOnset:{
            switch scenario {
            case 0: now+=50_000_001
            case 1: now=99
            case 2: stop=true
            default: return false
            }
            return true
        }) { sent.append($0);return true }
        #expect(sent.isEmpty && player.outstanding.isEmpty)
        if scenario==0 {
            #expect(player.fault == .lateEvent && player.maximumObservedLatenessNS==50_000_001)
        } else if scenario==1 {
            #expect(player.fault == .clockRegression)
        } else if scenario==2 {
            #expect(player.state == .stopped && player.fault==nil)
        } else {
            #expect(player.fault == .externalFailure)
        }
    }
}

@Test func boundedPlaybackOnsetAuthorizationFailureStillReleasesEarlierNote() throws {
    let plan=try BoundedMIDIPlayback(clip:playbackClip())
    var player=plan
    _=try player.begin(now:0)
    var admissions=0,commands:[SensorCommand]=[]
    player.advance(now:0,refreshNow:{0},authorizeOnset:{
        admissions+=1
        return admissions==1
    }) { commands.append($0);return true }
    #expect(admissions==2 && player.state == .faulted && player.fault == .externalFailure)
    #expect(commands.count==2 && commands.first?.value==90 && commands.last?.value==0)
    #expect(commands.first?.destination==commands.last?.destination && player.outstanding.isEmpty)
}

@Test func boundedPlaybackShortGateExpiringDuringAuthorizationNeverSounds() throws {
    let clip=MIDIClip(bpm:120,length:960,notes:[.init(start:0,duration:1,channel:0,pitch:60,velocity:90)])
    var player=try BoundedMIDIPlayback(clip:clip)
    _=try player.begin(now:0)
    var now:UInt64=0
    var sent:[SensorCommand]=[]
    player.advance(now:now,refreshNow:{now},authorizeOnset:{now=1_000_000;return true}) {
        sent.append($0);return true
    }
    #expect(player.fault == .expiredOnset && player.maximumObservedLatenessNS==1_000_000)
    #expect(sent.isEmpty && player.outstanding.isEmpty)
}

@Test func boundedPlaybackSlowLastOffCannotReportFinishedOrResendConfirmedOff() throws {
    let clip=MIDIClip(bpm:120,length:480,notes:[.init(start:0,duration:480,channel:0,pitch:60,velocity:90)])
    var player=try BoundedMIDIPlayback(clip:clip)
    _=try player.begin(now:0)
    var sent:[SensorCommand]=[]
    player.advance(now:0){sent.append($0);return true}
    player.advance(now:250_000_000,refreshNow:{300_000_001}){sent.append($0);return true}
    #expect(player.state == .faulted && player.fault == .lateSendCompletion)
    #expect(player.maximumObservedLatenessNS==50_000_001)
    #expect(sent.map(\.value)==[90,0] && player.outstanding.isEmpty)
    player.retryCleanup{sent.append($0);return true}
    #expect(sent.count==2)
}

@Test func boundedPlaybackSlowOnsetNeverAdmitsNextChordMember() throws {
    var player=try BoundedMIDIPlayback(clip:playbackClip())
    _=try player.begin(now:0)
    var sent:[SensorCommand]=[]
    player.advance(now:0,refreshNow:{50_000_001}){sent.append($0);return true}
    #expect(player.state == .faulted && player.fault == .lateSendCompletion)
    #expect(sent.map(\.value)==[90,0] && player.outstanding.isEmpty)
    #expect(sent.first?.destination==sent.last?.destination)
}

@Test func boundedPlaybackShortGateConsumedBySendRetiresOwnedNoteImmediately() throws {
    let clip=MIDIClip(bpm:120,length:960,notes:[.init(start:0,duration:1,channel:0,pitch:60,velocity:90)])
    var player=try BoundedMIDIPlayback(clip:clip)
    _=try player.begin(now:0)
    var sent:[SensorCommand]=[]
    player.advance(now:0,refreshNow:{1_000_000}){sent.append($0);return true}
    #expect(player.state == .faulted && player.fault == .expiredOnset)
    #expect(sent.map(\.value)==[90,0] && player.outstanding.isEmpty)
}

@Test func boundedMIDIClipAuditChecksEveryAmbiguousEdgeAndOwnedRetry() throws {
    var schedule=try BoundedMIDIPlayback(clip:playbackClip())
    let report=try BoundedMIDISimulation.audit(schedule)
    #expect(report.eventCount==6 && report.scenarios==12 && report.passedScenarios==12)
    #expect(report.maximumCleanupDebt==2 && report.allCleanAfterRetry)
    #expect(!report.hardware && !report.receiverConfirmed && schedule.state == .ready)
    _=try schedule.begin(now:0)
    #expect(throws:BoundedMIDISimulation.Failure.self) { _=try BoundedMIDISimulation.audit(schedule) }
}

@Test func boundedMIDIAuditCoversAllMaximumCapacityEdges() throws {
    let notes=(0..<256).map { index in
        MIDIClip.Note(start:0,duration:480,channel:index/128,pitch:index%128,velocity:90)
    }
    let schedule=try BoundedMIDIPlayback(clip:.init(bpm:120,length:960,notes:notes))
    let report=try BoundedMIDISimulation.audit(schedule)
    #expect(report.eventCount==512 && report.scenarios==1024 && report.passedScenarios==1024)
    #expect(report.maximumCleanupDebt==256 && report.allCleanAfterRetry)
}

@Test func boundedMIDIAuditDoesNotIncludeHistoricallyReleasedNotesInDebt() throws {
    let notes=(0..<8).map { index in
        MIDIClip.Note(start:index*120,duration:120,channel:0,pitch:60+index,velocity:90)
    }
    let schedule=try BoundedMIDIPlayback(clip:.init(bpm:120,length:960,notes:notes))
    let result=try BoundedMIDISimulation.audit(schedule)
    #expect(result.scenarios==32 && result.passedScenarios==32)
    #expect(result.maximumCleanupDebt==1 && result.allCleanAfterRetry)
}

@Test func boundedMIDIAuditCancellationReturnsNoPartialSuccessAndKeepsPreparedClip() throws {
    let schedule=try BoundedMIDIPlayback(clip:playbackClip())
    #expect(throws:CancellationError.self) {
        _=try BoundedMIDISimulation.audit(schedule,shouldStop:{true})
    }
    var checks=0
    #expect(throws:CancellationError.self) {
        _=try BoundedMIDISimulation.audit(schedule,shouldStop:{
            checks+=1
            return checks==5
        })
    }
    #expect(checks==5 && schedule.state == .ready && schedule.outstanding.isEmpty)
    let complete=try BoundedMIDISimulation.audit(schedule)
    #expect(complete.scenarios==complete.passedScenarios && complete.allCleanAfterRetry)
}
