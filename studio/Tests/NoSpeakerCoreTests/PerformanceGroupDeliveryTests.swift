import Foundation
import Testing
@testable import NoSpeakerCore

private func deliveryGroup(_ source: SensorSource, signal: SensorSignal = .contact,
                           note: Int = 60) -> PerformanceInstrumentGroup {
    .init(name:"Group",patch:.init(routes:[
        .init(id:"note",source:source,signal:signal,destination:.init(.note,number:note))
    ]))
}

@Test func groupDeliveryFailedOnsetRetainsDebtAndOtherGroupPlays() throws {
    let a = deliveryGroup(.trackpad)
    let b = deliveryGroup(.trackpad)
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[a,b]),allowLayering:true)
    let lease = try delivery.connect(.trackpad,now:1)
    let target = SensorDestination(.note,number:60)
    var attempted: [PerformanceGroupCommand] = []
    let first = delivery.frame(lease:lease,sequence:1,now:1,values:[.contact:1]) {
        attempted.append($0)
        return $0.groupID != a.id
    }
    #expect(first.failedGroups == [a.id])
    #expect(first.pendingCleanup == [a.id])
    #expect(first.accepted == 1)
    #expect(attempted.contains(.init(groupID:a.id,command:.init(target,value:0))))
    #expect(attempted.contains(.init(groupID:b.id,command:.init(target,value:100))))
    #expect(delivery.sessionCount == 1)
    attempted = []
    let up = delivery.frame(lease:lease,sequence:2,now:1.1,values:[:],releasing:[.contact]) {
        attempted.append($0); return true
    }
    #expect(attempted == [.init(groupID:b.id,command:.init(target,value:0))])
    #expect(up.pendingCleanup == [a.id])
    attempted = []
    let retry = delivery.retryCleanup(a.id) { attempted.append($0); return true }
    #expect(attempted == [.init(groupID:a.id,command:.init(target,value:0))])
    #expect(retry.pendingCleanup.isEmpty)
    #expect(delivery.faultedGroups == [a.id])
    let again = delivery.retryCleanup(a.id) { _ in Issue.record("Repeated cleanup"); return false }
    #expect(again.accepted == 0)
}

@Test func groupDeliveryStopsOnlyAttemptedTargetsAfterFailure() throws {
    let group = PerformanceInstrumentGroup(name:"Chord",patch:.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"b",source:.trackpad,signal:.contact,destination:.init(.note,number:64))
    ]))
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[group]))
    let lease = try delivery.connect(.trackpad,now:1)
    var commands: [SensorCommand] = []
    let result = delivery.frame(lease:lease,sequence:1,now:1,values:[.contact:1]) {
        commands.append($0.command)
        return $0.command.value == 0
    }
    #expect(commands.count == 2)
    #expect(commands.first?.value == 100)
    #expect(commands.last?.value == 0)
    #expect(commands.first?.destination == commands.last?.destination)
    #expect(result.failedGroups == [group.id])
    #expect(result.pendingCleanup.isEmpty)
    #expect(delivery.sessionCount == 0)
}

@Test func groupDeliveryFailedReleaseCannotBeSilentlyForgotten() throws {
    let a = deliveryGroup(.trackpad)
    let b = deliveryGroup(.magicMouse)
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[a,b]))
    let x = try delivery.connect(.trackpad,now:1)
    let y = try delivery.connect(.magicMouse,now:1)
    _ = delivery.frame(lease:x,sequence:1,now:1,values:[.contact:1]) { _ in true }
    _ = delivery.frame(lease:y,sequence:1,now:1,values:[.contact:1]) { _ in true }
    var commands: [PerformanceGroupCommand] = []
    let stop = delivery.stopGroup(a.id) { commands.append($0); return false }
    #expect(commands.count == 1 && commands.allSatisfy { $0.groupID == a.id })
    #expect(stop.pendingCleanup == [a.id])
    #expect(delivery.sessionCount == 1)
    let ignored = delivery.retryCleanup(b.id) { _ in Issue.record("Live group reset"); return true }
    #expect(ignored.accepted == 0 && ignored.pendingCleanup == [a.id])
    commands = []
    let all = delivery.panic { commands.append($0); return $0.groupID == b.id }
    #expect(Set(commands.map(\.groupID)) == [a.id,b.id])
    #expect(all.pendingCleanup == [a.id])
    #expect(delivery.retired && delivery.sessionCount == 0)
    #expect(throws: PerformanceGroupRouterError.retired) { try delivery.connect(.trackpad,now:2) }
    let retry = delivery.retryCleanup(a.id) { _ in true }
    #expect(retry.pendingCleanup.isEmpty)
}

@Test func groupDeliverySustainOnlyDoesNotEmitGainOrReleaseOtherGroup() throws {
    let pedal = SensorDestination(.sustain)
    let group = PerformanceInstrumentGroup(name:"Pedals",patch:.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:pedal),
        .init(id:"b",source:.magicMouse,signal:.contact,destination:pedal)
    ]))
    let other = deliveryGroup(.gamepad1,signal:.padA)
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[group,other]))
    let x = try delivery.connect(.trackpad,now:1)
    let y = try delivery.connect(.magicMouse,now:1)
    let z = try delivery.connect(.gamepad1,now:1)
    _ = delivery.frame(lease:z,sequence:1,now:1,values:[.padA:1]) { _ in true }
    var events: [PerformanceGroupCommand] = []
    _ = delivery.frame(lease:x,sequence:1,now:1,values:[.contact:1]) { events.append($0); return true }
    _ = delivery.frame(lease:y,sequence:1,now:1,values:[.contact:1]) { events.append($0); return true }
    _ = delivery.disconnect(x) { events.append($0); return true }
    _ = delivery.disconnect(y) { events.append($0); return true }
    #expect(events == [
        .init(groupID:group.id,command:.init(pedal,value:127)),
        .init(groupID:group.id,command:.init(pedal,value:0))
    ])
    #expect(delivery.sessionCount == 1)
}

@Test func groupDeliveryRetriesFailedNeutralCommandOnly() throws {
    let group = deliveryGroup(.trackpad)
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[group]))
    let lease = try delivery.connect(.trackpad,now:1)
    _ = delivery.frame(lease:lease,sequence:1,now:1,values:[.contact:1]) { _ in true }
    var commands: [SensorCommand] = []
    let release = delivery.frame(lease:lease,sequence:2,now:1.1,values:[:],releasing:[.contact]) {
        commands.append($0.command); return false
    }
    #expect(commands.count == 2 && commands.allSatisfy { $0.value == 0 })
    #expect(release.pendingCleanup == [group.id])
    commands = []
    let retry = delivery.retryCleanup(group.id) { commands.append($0.command); return true }
    #expect(commands.count == 1 && commands.first?.value == 0)
    #expect(retry.pendingCleanup.isEmpty)
}


@Test func groupReceiptExpiryStopsOnlyAttemptedWireTargetsAndKeepsIndependentGroup() throws {
    let chord = PerformanceInstrumentGroup(name:"Chord",patch:.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"b",source:.trackpad,signal:.contact,destination:.init(.note,number:64))
    ]))
    let other = deliveryGroup(.gamepad1,signal:.padA,note:67)
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[chord,other]))
    let x = try delivery.connect(.trackpad,now:1)
    let y = try delivery.connect(.gamepad1,now:1)
    _ = delivery.frame(lease:y,sequence:1,now:1,values:[.padA:1]) { _ in true }
    var fresh = true
    var attempted:[PerformanceGroupCommand] = []
    let report = delivery.admittedFrame(lease:x,sequence:1,now:1,values:[.contact:1],releasing:[],
                                         admit:{fresh}) {
        attempted.append($0)
        if $0.command.value > 0 { fresh = false; return true }
        return false
    }
    #expect(report.admissionExpired)
    #expect(report.failedGroups == [chord.id] && report.pendingCleanup == [chord.id])
    #expect(attempted.count == 2 && attempted.allSatisfy { $0.groupID == chord.id })
    #expect(attempted.first?.command.value == 100 && attempted.last?.command.value == 0)
    #expect(attempted.first?.command.destination == attempted.last?.command.destination)
    #expect(!delivery.hasLease(x) && delivery.hasLease(y))
    attempted = []
    let retry = delivery.retryCleanup(chord.id) { attempted.append($0); return true }
    #expect(attempted.count == 1 && attempted.first?.command.value == 0)
    #expect(retry.pendingCleanup.isEmpty && delivery.hasLease(y))
}

@Test func groupReceiptExpiryRollsBackSilentJoinWithoutRetiringLiveGroup() throws {
    let note = SensorDestination(.note,number:60)
    let group = PerformanceInstrumentGroup(name:"Shared",patch:.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:note),
        .init(id:"b",source:.magicMouse,signal:.contact,destination:note)
    ]))
    var delivery = try PerformanceGroupDelivery(profile:.init(groups:[group]))
    let x = try delivery.connect(.trackpad,now:1)
    let y = try delivery.connect(.magicMouse,now:1)
    _ = delivery.frame(lease:x,sequence:1,now:1,values:[.contact:1]) { _ in true }
    var checks = 0
    let rejected = delivery.admittedFrame(lease:y,sequence:1,now:1,values:[.contact:1],releasing:[],
                                           admit:{ checks += 1; return checks == 1 }) { _ in
        Issue.record("Silent join must not send")
        return false
    }
    #expect(rejected.admissionExpired && rejected.failedGroups.isEmpty && rejected.pendingCleanup.isEmpty)
    #expect(delivery.hasLease(x) && delivery.hasLease(y))
    var commands:[PerformanceGroupCommand] = []
    _ = delivery.disconnect(x) { commands.append($0); return true }
    #expect(commands == [.init(groupID:group.id,command:.init(note,value:0))])
    _ = delivery.disconnect(y) { _ in Issue.record("Unadmitted owner has no debt"); return false }
    #expect(delivery.faultedGroups.isEmpty)
}


@Test func groupDisconnectFencesRestorationButNotCustomNeutralOrNoteOff() throws {
    let cc = SensorDestination(.controlChange,number:74)
    let note = SensorDestination(.note,number:60)
    let shared = PerformanceInstrumentGroup(name:"Shared",patch:.init(routes:[
        .init(id:"low",source:.lid,signal:.angle,destination:cc,priority:0,response:.init(release:0.25)),
        .init(id:"high",source:.touchBar,signal:.x,destination:cc,priority:10,response:.init(release:0.25))
    ]))
    let independent = PerformanceInstrumentGroup(name:"Other",patch:.init(routes:[
        .init(id:"note",source:.touchBar,signal:.x,destination:note)
    ]))
    for stallAfterRestoration in [false,true] {
        var state = try PerformanceGroupDelivery(profile:.init(groups:[shared,independent]),allowLayering:true)
        let low = try state.connect(.lid,now:1)
        let high = try state.connect(.touchBar,now:1)
        _ = state.frame(lease:low,sequence:1,now:1,values:[.angle:0.4]) { _ in true }
        _ = state.frame(lease:high,sequence:1,now:1,values:[.x:0.8]) { _ in true }
        var fresh = stallAfterRestoration
        var wire:[PerformanceGroupCommand] = []
        let report = state.disconnectBatch([high],admitRestoration:{fresh}) {
            wire.append($0)
            if $0.groupID == shared.id && $0.command.value == 51 { fresh = false }
            return true
        }
        #expect(report.admissionExpired && report.failedGroups == [shared.id])
        #expect(wire.filter { $0.groupID == shared.id }.map(\.command.value) == (stallAfterRestoration ? [51,32] : [32]))
        #expect(wire.contains(.init(groupID:independent.id,command:.init(note,value:0))))
        #expect(report.pendingCleanup.isEmpty && !state.hasLease(low) && !state.hasLease(high))
        #expect(state.faultedGroups == [shared.id])
    }
}

@Test func groupDisconnectAlwaysAttemptsConfiguredNeutralEvenWhenRestoreNotAdmitted() throws {
    let cc = SensorDestination(.controlChange,number:74)
    let group = PerformanceInstrumentGroup(name:"Custom release",patch:.init(routes:[
        .init(id:"cc",source:.lid,signal:.angle,destination:cc,response:.init(release:0.25))
    ]))
    var state = try PerformanceGroupDelivery(profile:.init(groups:[group]))
    let lease = try state.connect(.lid,now:1)
    _ = state.frame(lease:lease,sequence:1,now:1,values:[.angle:0.8]) { _ in true }
    var wire:[PerformanceGroupCommand] = []
    let report = state.disconnectBatch([lease],admitRestoration:{false}) { wire.append($0); return true }
    #expect(!report.admissionExpired && report.failedGroups.isEmpty && report.pendingCleanup.isEmpty)
    #expect(wire == [.init(groupID:group.id,command:.init(cc,value:32))])
}
