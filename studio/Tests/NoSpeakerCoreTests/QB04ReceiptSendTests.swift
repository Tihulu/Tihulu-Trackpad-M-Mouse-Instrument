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
