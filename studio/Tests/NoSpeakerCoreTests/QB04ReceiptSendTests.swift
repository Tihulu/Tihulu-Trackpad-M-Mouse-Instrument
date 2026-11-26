import Testing
@testable import NoSpeakerCore

// Baseline negative regression: the final synchronous consumer may consume
// the remainder of the receipt window. Reporting success is then incorrect.
@Test func qb04DispatchMustRejectExpiredFinalConsumer() {
    var now=1.01
    var trace:[String]=[]
    let accepted=TouchPublicationAdmission.dispatch(queuedAt:1,now:{now},prepare:{
        trace.append("pedal")
    },touch:{
        trace.append("touch")
    },helper:{
        trace.append("helper")
        now=1+TouchPublicationAdmission.maximumAge
    })
    #expect(trace == ["pedal","touch","helper"])
    #expect(!accepted)
}

// A clock that moves backwards inside a publication must not admit another
// consumer even when both observations independently fit the receipt window.
@Test func qb04DispatchMustRejectRegressingClock() {
    var now=10.10
    var trace:[String]=[]
    let accepted=TouchPublicationAdmission.dispatch(queuedAt:10,now:{now},prepare:{
        trace.append("pedal")
        now=10.05
    },touch:{trace.append("touch")},helper:{trace.append("helper")})
    #expect(!accepted)
    #expect(trace == ["pedal"])
}

private func qbNote(_ pitch:Int,_ velocity:Int)->SensorCommand {
    .init(.init(.note,number:pitch),value:velocity)
}

@Test func qb04NoteRearticulationChecksClockAfterRelease() {
    for blocked in [false,true] {
        var owners=LegacyNoteOwners<String>()
        _=owners.press("finger",channel:0,note:60,velocity:90)
        _=owners.press("screen",channel:0,note:67,velocity:90)
        var fence=PhysicalReceiptSendFence(receipt:1,maximumAge:0.150)
        var now=1.01
        var events:[SensorCommand]=[]
        let accepted=owners.pressAdmitted("finger",channel:0,note:62,velocity:90,
            permits:{fence.permits(now:now)},send:{command in
                events.append(command)
                if blocked { now=1.15 }
            })
        #expect(accepted == !blocked)
        #expect(events == (blocked ? [qbNote(60,0)] : [qbNote(60,0),qbNote(62,90)]))
        #expect(owners.active.contains(qbNote(67,90).destination))
        let fingerCleanup=owners.release("finger")
        let screenCleanup=owners.release("screen")
        #expect(fingerCleanup == (blocked ? [] : [qbNote(62,0)]))
        #expect(screenCleanup == [qbNote(67,0)])
    }
}

@Test func qb04ChordStopsAtFirstSlowOnsetWithoutAcquiringUnattemptedDebt() {
    for blocked in [false,true] {
        var chord=PhysicalChordGates<Int>()
        var owners=LegacyNoteOwners<String>()
        let targets=Set([60,64,67].map { qbNote($0,90).destination })
        // Unrelated performance owner must survive scoped physical retirement.
        _=owners.press("screen",channel:0,note:67,velocity:95)
        var now=10.01
        var fence=PhysicalReceiptSendFence(receipt:10,maximumAge:0.150)
        var events:[SensorCommand]=[]
        var debt=LegacyGateReleaseDebt()
        let accepted=chord.reconcileAdmitted([1:targets],velocity:[1:90],ledger:&owners,
            owner:{contact,target in "\(contact):\(target.number)"},
            permits:{fence.permits(now:now)},send:{command in
                events.append(command)
                // Simulate an ambiguous failed onset. The attempted edge must
                // remain debt even though later positive sends are not admitted.
                debt.record(.init(command.value == 0 ? 0x80 : 0x90,
                                  command.destination.number,command.value),succeeded:!blocked)
                if blocked { now=10.15 }
            })
        #expect(accepted == !blocked)
        #expect(events == (blocked ? [qbNote(60,90)] : [qbNote(60,90),qbNote(64,90)]))
        let cleanup=chord.reconcile([:],velocity:[:],ledger:&owners,
            owner:{contact,target in "\(contact):\(target.number)"})
        #expect(cleanup == (blocked ? [qbNote(60,0)] : [qbNote(60,0),qbNote(64,0)]))
        if blocked {
            #expect(debt.pending == [.init(0x80,60,0)])
            debt.record(.init(0x80,60,0),succeeded:false)
            #expect(debt.pending == [.init(0x80,60,0)])
            debt.record(.init(0x80,60,0),succeeded:true)
            #expect(debt.isEmpty)
        }
        #expect(owners.active == [qbNote(67,90).destination])
        let screenCleanup=owners.release("screen")
        #expect(screenCleanup == [qbNote(67,0)])
    }
}

@Test func qb04ChordFreshHandoffKeepsSharedGateWithoutOffOnPulse() {
    let target=qbNote(60,90).destination
    var chord=PhysicalChordGates<Int>()
    var owners=LegacyNoteOwners<String>()
    var events:[SensorCommand]=[]
    func owner(_ c:Int,_ d:SensorDestination)->String { "\(c):\(d.number)" }
    let first=chord.reconcileAdmitted([1:[target]],velocity:[1:90],ledger:&owners,owner:owner,
        permits:{true},send:{events.append($0)})
    let second=chord.reconcileAdmitted([2:[target]],velocity:[2:90],ledger:&owners,owner:owner,
        permits:{true},send:{events.append($0)})
    #expect(first && second)
    #expect(events == [qbNote(60,90)])
    let cleanup=chord.reconcile([:],velocity:[:],ledger:&owners,owner:owner)
    #expect(cleanup == [qbNote(60,0)])
}

@Test func qb04FenceLatchesExactDeadlineAndClockRegression() {
    for age in [0.1,0.150,0.35] {
        for origin in [1.0,10,1000,100000] {
            let deadline=origin+age
            var exact=PhysicalReceiptSendFence(receipt:origin,maximumAge:age)
            let before=exact.permits(now:deadline.nextDown)
            let at=exact.permits(now:deadline)
            let recovered=exact.permits(now:origin)
            #expect(before && !at && !recovered)
            var backwards=PhysicalReceiptSendFence(receipt:origin,maximumAge:age,initialNow:origin+age/2)
            let regressed=backwards.permits(now:origin)
            let caughtUp=backwards.permits(now:origin+age/2)
            #expect(!regressed && !caughtUp)
        }
    }
}

@Test func builderReceiptExpiryNeverCreatesUnattemptedOutputDebt() {
    for stall in [false,true] {
        var ledger=PatchOutputLedger()
        var fence:PhysicalReceiptSendFence? = .init(receipt:10,maximumAge:0.35)
        var now=10.01
        var sent:[SensorCommand]=[]
        let outcome=PhysicalReceiptCommandBatch.dispatch([qbNote(60,90),qbNote(64,90)],
            fence:&fence,now:{now},send:{command in
                ledger.deliver(command,send:{wire in
                    sent.append(wire)
                    if stall { now=10.35 }
                    return true
                })
            })
        #expect(outcome == (stall ? .expired : .completed))
        #expect(sent == (stall ? [qbNote(60,90)] : [qbNote(60,90),qbNote(64,90)]))
        var cleanup:[SensorCommand]=[]
        let cleaned=ledger.releaseAll(send:{cleanup.append($0);return true})
        #expect(cleaned && ledger.outstanding.isEmpty)
        #expect(cleanup == (stall ? [qbNote(60,0)] : [qbNote(60,0),qbNote(64,0)]))
    }
}

@Test func builderReceiptTransportFailureRetainsOnlyAttemptedDebt() {
    var ledger=PatchOutputLedger()
    var fence:PhysicalReceiptSendFence? = .init(receipt:1,maximumAge:0.35)
    var sent:[SensorCommand]=[]
    let outcome=PhysicalReceiptCommandBatch.dispatch([qbNote(60,90),qbNote(64,90)],
        fence:&fence,now:{1.01},send:{command in
            ledger.deliver(command,send:{sent.append($0);return false})
        })
    #expect(outcome == .transportFailed && sent == [qbNote(60,90)])
    #expect(ledger.outstanding == [qbNote(60,90).destination])
    let failed=ledger.releaseAll(send:{_ in false})
    #expect(!failed && ledger.outstanding == [qbNote(60,90).destination])
    let cleaned=ledger.releaseAll(send:{_ in true})
    #expect(cleaned && ledger.outstanding.isEmpty)
}

@Test func builderReceiptRejectsFinalSlowSendAndBackwardClock() {
    for end in [0.99,1.35] {
        var fence:PhysicalReceiptSendFence? = .init(receipt:1,maximumAge:0.35)
        var now=1.01
        let result=PhysicalReceiptCommandBatch.dispatch([qbNote(60,90)],fence:&fence,
            now:{now},send:{_ in now=end;return true})
        #expect(result == .expired)
    }
    var unfenced:PhysicalReceiptSendFence?
    var sent:[SensorCommand]=[]
    let result=PhysicalReceiptCommandBatch.dispatch([qbNote(60,90)],fence:&unfenced,
        now:{ .nan },send:{sent.append($0);return true})
    #expect(result == .completed && sent == [qbNote(60,90)])
}

@Test func builderCameraBatchUsesExistingQuarterSecondDeadline() {
    var fence:PhysicalReceiptSendFence? = .init(receipt:10,maximumAge:0.25)
    var now=10.01
    var sent:[SensorCommand]=[]
    let result=PhysicalReceiptCommandBatch.dispatch([qbNote(60,90),qbNote(64,90)],
        fence:&fence,now:{now},send:{cmd in sent.append(cmd);now=10.25;return true})
    #expect(result == .expired && sent == [qbNote(60,90)])
}

private func qbPedal(_ channel:Int,_ value:Int)->SensorCommand {
    .init(.init(.sustain,channel:channel),value:value)
}

@Test func qb04PedalSlowFirstOnsetDoesNotAcquireLaterChannel() {
    var owners=LegacySustainOwners()
    _=owners.replace(.touchBar,channels:[9])
    var fence=PhysicalReceiptSendFence(receipt:10,maximumAge:0.150)
    var now=10.01
    var sent:[SensorCommand]=[]
    let accepted=owners.replaceFrameAdmitted([.touch:[1,2],.helper:[2]],
        permits:{fence.permits(now:now)},send:{command in
            sent.append(command)
            now=10.15
        })
    #expect(!accepted && sent == [qbPedal(1,127)])
    #expect(owners.channels(for:.touch)==[1] && owners.channels(for:.helper).isEmpty)
    let cleanup=owners.replaceFrame([.touch:[],.helper:[]])
    #expect(cleanup == [qbPedal(1,0)] && owners.active == [9])
}

@Test func qb04PedalFreshHandoffAndReleaseBeforeExpiredAttack() {
    var owners=LegacySustainOwners()
    _=owners.replaceFrame([.touch:[1,2],.touchBar:[9]])
    var sent:[SensorCommand]=[]
    let handoff=owners.replaceFrameAdmitted([.touch:[2],.helper:[1]],
        permits:{true},send:{sent.append($0)})
    #expect(handoff && sent.isEmpty && owners.active == [1,2,9])
    var now=1.01
    var fence=PhysicalReceiptSendFence(receipt:1,maximumAge:0.150)
    let accepted=owners.replaceFrameAdmitted([.touch:[3],.helper:[1]],
        permits:{fence.permits(now:now)},send:{command in sent.append(command);now=1.15})
    #expect(!accepted && sent == [qbPedal(2,0)])
    #expect(owners.active == [1,9] && owners.channels(for:.touch).isEmpty)
}

@Test func qb04PedalExpiredSilentJoinNeverAcquiresOwnership() {
    var owners=LegacySustainOwners()
    _=owners.replace(.touchBar,channels:[4])
    var sent:[SensorCommand]=[]
    let accepted=owners.replaceFrameAdmitted([.helper:[4]],permits:{false},send:{sent.append($0)})
    #expect(!accepted && sent.isEmpty && owners.channels(for:.helper).isEmpty)
    let cleanup=owners.replace(.touchBar,channels:[])
    #expect(cleanup == [qbPedal(4,0)])
}


@Test func qb04ContinuousOwnerDoesNotAcquireUnsentTargetsAfterStall() {
    let a=SensorDestination(.controlChange,number:1)
    let b=SensorDestination(.controlChange,number:74)
    let independent=SensorDestination(.controlChange,channel:9,number:74)
    var owners=LegacyContinuousOwners()
    _=owners.set(.touchBar,target:independent,value:.init(50,neutral:0))
    var now=10.01
    var fence=PhysicalReceiptSendFence(receipt:10,maximumAge:0.150)
    var sent:[LegacyContinuousOwners.Update]=[]
    let ok=owners.replaceAdmitted(.helper,values:[a:.init(64,neutral:0),b:.init(80,neutral:0)],
        permits:{fence.permits(now:now)},send:{update in sent.append(update);now=10.15;return true})
    #expect(!ok && sent.map(\.target)==[a])
    #expect(Set(owners.values(for:.helper).keys)==[a])
    let cleanup=owners.release(.helper)
    #expect(cleanup.map(\.target)==[a] && cleanup.first?.value==0)
    #expect(owners.values(for:.touchBar)[independent]?.value==50)
}

@Test func qb04ContinuousSilentJoinRequiresFreshReceiptAndFailedWriteIsNotAnOwner() {
    let a=SensorDestination(.controlChange,number:1)
    var owners=LegacyContinuousOwners()
    _=owners.set(.touch,target:a,value:.init(64,neutral:0))
    let blocked=owners.replaceAdmitted(.helper,values:[a:.init(80,neutral:0)],
        permits:{false},send:{_ in Issue.record("Unexpected wire");return true})
    #expect(!blocked && owners.values(for:.helper).isEmpty)
    let failed=owners.replaceAdmitted(.touch,values:[a:.init(90,neutral:0)],
        permits:{true},send:{_ in false})
    #expect(!failed && owners.values(for:.touch)[a]?.value==64)
}

@Test func qb04RangeExpiryClearsSelectorsWithoutLateDataEntries() {
    for stopAfter in 0...4 {
        var sent:[Int]=[]
        var began=0
        let result=LegacyAdmittedBendRange.send(semitones:12,permits:{sent.count<stopAfter},
            begin:{began+=1},wire:{cc,_ in sent.append(cc);return true})
        if stopAfter==0 {
            #expect(!result.attempted && began==0 && sent.isEmpty)
        } else {
            #expect(result.attempted && began==1 && result.cleanupConfirmed)
            #expect(sent==Array([101,100,6,38].prefix(stopAfter))+[101,100])
            #expect(result.dataAttempted == (stopAfter>=3))
            #expect(result.completed == (stopAfter==4))
        }
    }
}

@Test func qb04RangeFailedSelectorCleanupCannotReportSuccess() {
    var sent:[Int]=[]
    let result=LegacyAdmittedBendRange.send(semitones:12,permits:{true},begin:{},wire:{cc,value in
        sent.append(cc)
        return !(cc==101 && value==127)
    })
    #expect(result.attempted && result.dataAttempted && !result.completed && !result.cleanupConfirmed)
    #expect(sent == [101,100,6,38,101,100])
}


@Test func qb04PressureSlowChannelDoesNotInstallUnsentChannel() {
    var owner=LegacyChannelPressure()
    _=owner.replace([9:50])
    var now=1.01
    var fence=PhysicalReceiptSendFence(receipt:1,maximumAge:0.150)
    var wire:[LegacyChannelPressure.Update]=[]
    let result=owner.replaceAdmitted([1:80,2:90,9:50],
        permits:{fence.permits(now:now)},send:{wire.append($0);now=1.15;return true})
    #expect(!result && wire == [.init(1,80)])
    #expect(owner.values == [1:80,9:50])
    let release=owner.release(1)
    #expect(release == [.init(1,0)] && owner.values == [9:50])
}

@Test func qb04PressureFailedWriteKeepsPriorLogicalStateAndNoLaterWrites() {
    var owner=LegacyChannelPressure()
    _=owner.replace([1:40])
    var wire:[LegacyChannelPressure.Update]=[]
    let result=owner.replaceAdmitted([1:90,2:100],permits:{true},send:{
        wire.append($0);return false
    })
    #expect(!result && wire == [.init(1,90)] && owner.values == [1:40])
}

@Test func qb04RangeFirstAdmissionAuthorizesExactlyOneAttempt() {
    var checks=0,begins=0
    var wire:[Int]=[]
    let result=LegacyAdmittedBendRange.send(semitones:12,permits:{checks+=1;return checks==1},
        begin:{begins+=1},wire:{cc,_ in wire.append(cc);return true})
    #expect(result.attempted && !result.completed && result.cleanupConfirmed && !result.dataAttempted)
    #expect(begins==1 && wire == [101,101,100])
}
