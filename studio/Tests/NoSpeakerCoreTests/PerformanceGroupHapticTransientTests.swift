import Foundation
import Testing
@testable import NoSpeakerCore

private func transientGroup(_ source:SensorSource,_ note:Int) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[
        .init(id:"note",source:source,signal:.padA,destination:.init(.note,number:note)),
        .init(id:"volume",source:source,signal:.padLSX,destination:.init(.controlChange,number:7),response:.init(release:0))
    ]))
}
private func transientCommand(_ group:PerformanceInstrumentGroup,_ destination:SensorDestination,_ value:Int) -> PerformanceGroupCommand {
    .init(groupID:group.id,command:.init(destination,value:value))
}

@Test func groupShortNoteSurvivesBetweenTicksAndIsConsumedOnlyOnce() throws {
    let group = transientGroup(.gamepad1,60)
    var projection = try PerformanceGroupHapticProjection(profile:.init(groups:[group]),selected:[group.id])
    let note = SensorDestination(.note,number:60)
    projection.observe(transientCommand(group,note,100),accepted:true,now:1.001)
    projection.observe(transientCommand(group,note,0),accepted:true,now:1.005)
    let snapshot = projection.snapshot(now:1.006)
    #expect(snapshot.held == nil && snapshot.attacks.count == 1)
    var mailbox = GroupHapticMailbox(now:1)
    let accepted = mailbox.publish(snapshot:snapshot,masterLevel:1,now:1.006)
    #expect(accepted)
    let played = mailbox.read(now:1.018)
    #expect(played?.frame?.tones.count == 1)
    #expect(played?.frame?.durationMS == 18)
    let silent = mailbox.read(now:1.036)
    #expect(silent?.frame == nil)
    let next = projection.snapshot(now:1.037)
    #expect(next.attacks.isEmpty)
}

@Test func groupTransientDoesNotCaptureOtherHeldNotesAndAgeIsNeverRenewed() throws {
    let a = transientGroup(.gamepad1,60), b = transientGroup(.gamepad2,64)
    var projection = try PerformanceGroupHapticProjection(profile:.init(groups:[a,b]),selected:[a.id,b.id])
    projection.observe(transientCommand(a,.init(.note,number:60),100),accepted:true)
    projection.observe(transientCommand(b,.init(.note,number:64),100),accepted:true,now:1.001)
    projection.observe(transientCommand(b,.init(.note,number:64),0),accepted:true,now:1.002)
    let snapshot = projection.snapshot(now:1.030)
    #expect(snapshot.held?.tones.count == 1 && snapshot.attacks.first?.frame.tones.count == 1)
    #expect(snapshot.held?.tones.first?.frequencyHz != snapshot.attacks.first?.frame.tones.first?.frequencyHz)
    var mailbox = GroupHapticMailbox(now:1)
    _ = mailbox.publish(snapshot:snapshot,masterLevel:1,now:1.030)
    let expired = mailbox.read(now:1.043)
    #expect(expired?.frame == snapshot.held)
}

@Test func groupTransientRetirementAndGainChangeClearTransferredAttacks() throws {
    let a = transientGroup(.gamepad1,60), b = transientGroup(.gamepad2,64)
    let profile = PerformanceGroupProfile(groups:[a,b])
    for scenario in 0..<3 {
        var projection = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id])
        var mailbox = GroupHapticMailbox(now:1)
        projection.observe(transientCommand(a,.init(.note,number:60),100),accepted:true,now:1.001)
        projection.observe(transientCommand(a,.init(.note,number:60),0),accepted:true,now:1.002)
        projection.observe(transientCommand(b,.init(.note,number:64),100),accepted:true)
        _ = mailbox.publish(snapshot:projection.snapshot(now:1.003),masterLevel:1,now:1.003)
        if scenario == 0 { projection.retire(a.id) }
        if scenario == 1 {
            projection.observe(transientCommand(a,.init(.note,number:60),100),accepted:false,now:1.004)
        }
        if scenario == 2 {
            projection.observe(transientCommand(a,.init(.controlChange,number:7),0),accepted:true,now:1.004)
        }
        let next = projection.snapshot(now:1.005)
        _ = mailbox.publish(snapshot:next,masterLevel:1,now:1.005)
        let played = mailbox.read(now:1.018)
        #expect(played?.frame == next.held && played?.frame?.tones.count == 1)
    }
}

@Test func groupTransientCapacityAndMuteAndCloseAreBounded() throws {
    let group = transientGroup(.gamepad1,60)
    var projection = try PerformanceGroupHapticProjection(profile:.init(groups:[group]),selected:[group.id])
    for i in 0..<10 {
        let time = 1+Double(i)*0.001
        projection.observe(transientCommand(group,.init(.note,number:60),100),accepted:true,now:time)
        projection.observe(transientCommand(group,.init(.note,number:60),0),accepted:true,now:time)
    }
    let snapshot = projection.snapshot(now:1.01)
    #expect(snapshot.attacks.count == 4)
    var mailbox = GroupHapticMailbox(now:1)
    _ = mailbox.publish(snapshot:snapshot,masterLevel:1,now:1.01)
    _ = mailbox.publish(frame:nil,masterLevel:0,now:1.011)
    _ = mailbox.publish(frame:nil,masterLevel:1,now:1.012)
    let silent = mailbox.read(now:1.018)
    #expect(silent?.frame == nil)
    _ = mailbox.publish(snapshot:snapshot,masterLevel:1,now:1.019)
    mailbox.close()
    let closed = mailbox.read(now:1.020)
    #expect(closed == nil && mailbox.retired)
}
