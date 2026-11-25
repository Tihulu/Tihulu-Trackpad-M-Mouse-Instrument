import Foundation
import Testing
@testable import NoSpeakerCore

private func mpeHapticGroup(_ source:SensorSource) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[
        .init(id:"note",source:source,signal:.padA,destination:.init(.note,channel:3,number:62)),
        .init(id:"note2",source:source,signal:.padB,destination:.init(.note,channel:3,number:64)),
        .init(id:"sustain",source:source,signal:.padRT,destination:.init(.sustain,channel:3)),
        .init(id:"bend",source:source,signal:.padLSX,destination:.init(.pitchBend,channel:3)),
        .init(id:"volume",source:source,signal:.padRSY,destination:.init(.controlChange,channel:3,number:7),response:.init(release:0))
    ]))
}
private func mpeHapticSpec(_ cents:Int) -> PerformanceGroupTuningPlan.Specification {
    var scale = CustomScale()
    scale.centOffsets = [2:cents]
    return .init(scale:scale,root:60)
}

@Test func groupMPEHapticPreparedWirePreservesDistinctPortIntonationAndMasterBend() throws {
    let a = mpeHapticGroup(.gamepad1), b = mpeHapticGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let tuning = [a.id:mpeHapticSpec(-20),b.id:mpeHapticSpec(20)]
    let plan = try PerformanceGroupTuningPlan(profile:profile,tuning:tuning)
    var output = try PerformanceGroupTunedDelivery(profile:profile,tuning:tuning)
    let prepared = output.prepare { _ in true }
    #expect(prepared)
    var projection = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id],preparedTuning:tuning)
    let x = try output.connect(.gamepad1,now:1), y = try output.connect(.gamepad2,now:1)
    let sink:(PerformanceGroupCommand)->Bool = { item in projection.observe(item,accepted:true,now:1.01);return true }
    _ = output.frame(lease:x,sequence:1,now:1.01,values:[.padA:1],send:sink)
    _ = output.frame(lease:y,sequence:1,now:1.01,values:[.padA:1],send:sink)
    let base = try MusicTheory.frequency(midi:62)
    let first = try #require(plan.zones[a.id]?.members.first?.bend)
    let second = try #require(plan.zones[b.id]?.members.first?.bend)
    let expectedA = base*pow(2,Double(first-8192)/8192*2/12)
    let expectedB = base*pow(2,Double(second-8192)/8192*2/12)
    let frame = try #require(projection.frame())
    let pitches = frame.tones.map(\.frequencyHz).sorted()
    #expect(pitches.count == 2)
    #expect(abs(pitches[0]-expectedA) < 0.001 && abs(pitches[1]-expectedB) < 0.001)
    let bend = try #require(plan.translate(.init(groupID:a.id,command:.init(.init(.pitchBend,channel:3),value:12288))))
    projection.observe(bend,accepted:true)
    let bent = try #require(projection.frame())
    #expect(bent.tones.contains { abs($0.frequencyHz-expectedA*pow(2,1.0/12)) < 0.001 })
    #expect(bent.tones.contains { abs($0.frequencyHz-expectedB) < 0.001 })
}

@Test func groupMPEHapticMasterSustainAndGainRemainPortScoped() throws {
    let a = mpeHapticGroup(.gamepad1), b = mpeHapticGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let tuning = [a.id:mpeHapticSpec(-20)]
    let plan = try PerformanceGroupTuningPlan(profile:profile,tuning:tuning)
    var projection = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id],preparedTuning:tuning)
    func wire(_ group:PerformanceInstrumentGroup,_ d:SensorDestination,_ v:Int) throws -> PerformanceGroupCommand {
        try #require(plan.translate(.init(groupID:group.id,command:.init(d,value:v))))
    }
    let note = SensorDestination(.note,channel:3,number:62)
    let pedal = SensorDestination(.sustain,channel:3)
    let gain = SensorDestination(.controlChange,channel:3,number:7)
    projection.observe(try wire(a,note,100),accepted:true)
    projection.observe(try wire(a,pedal,127),accepted:true)
    projection.observe(try wire(a,note,0),accepted:true)
    projection.observe(try wire(b,note,100),accepted:true)
    #expect(projection.frame()?.tones.count == 2)
    projection.observe(try wire(a,gain,0),accepted:true)
    #expect(projection.frame()?.tones.count == 1)
    projection.observe(try wire(a,gain,127),accepted:true)
    #expect(projection.frame()?.tones.count == 2)
    projection.observe(try wire(a,pedal,0),accepted:true)
    #expect(projection.frame()?.tones.count == 1)
    projection.observe(try wire(b,note,0),accepted:true)
    #expect(projection.frame() == nil)
}

@Test func groupMPEHapticRejectsLogicalAndUnexpectedSetupTargets() throws {
    let a = mpeHapticGroup(.gamepad1), b = mpeHapticGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let tuning = [a.id:mpeHapticSpec(-20)]
    var projection = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id],preparedTuning:tuning)
    projection.observe(.init(groupID:b.id,command:.init(.init(.note,channel:3,number:62),value:100)),accepted:true)
    projection.observe(.init(groupID:a.id,command:.init(.init(.note,channel:3,number:62),value:100)),accepted:true)
    #expect(projection.activeGroups == [b.id] && projection.frame()?.tones.count == 1)
    var another = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id],preparedTuning:tuning)
    another.observe(.init(groupID:a.id,command:.init(.init(.controlChange,channel:0,number:101),value:0)),accepted:true)
    #expect(another.activeGroups.isEmpty)
}


@Test func groupMPEHapticShortAttackMatchesWirePitchAndFailsClosedOnCleanup() throws {
    let a = mpeHapticGroup(.gamepad1), b = mpeHapticGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let tuning = [a.id:mpeHapticSpec(-20),b.id:mpeHapticSpec(20)]
    var output = try PerformanceGroupTunedDelivery(profile:profile,tuning:tuning)
    let prepared = output.prepare { _ in true }
    #expect(prepared)
    var haptic = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id],preparedTuning:tuning)
    let x = try output.connect(.gamepad1,now:1), y = try output.connect(.gamepad2,now:1)
    var time = 1.01
    let sink:(PerformanceGroupCommand)->Bool = { item in
        haptic.observe(item,accepted:true,now:time)
        return true
    }
    _ = output.frame(lease:x,sequence:1,now:time,values:[.padA:1],send:sink)
    let held = try #require(haptic.frame())
    time = 1.014
    _ = output.frame(lease:x,sequence:2,now:time,values:[:],releasing:[.padA],send:sink)
    var mailbox = GroupHapticMailbox(now:1)
    let first = haptic.snapshot(now:time)
    #expect(first.held == nil && first.attacks.count == 1)
    #expect(first.attacks.first?.frame.tones.first?.frequencyHz == held.tones.first?.frequencyHz)
    _ = mailbox.publish(snapshot:first,masterLevel:1,now:time)
    time = 1.015
    _ = output.frame(lease:x,sequence:3,now:time,values:[.padA:1],send:sink)
    _ = output.frame(lease:y,sequence:1,now:time,values:[.padA:1],send:sink)
    time = 1.016
    let failed = output.frame(lease:x,sequence:4,now:time,values:[:],releasing:[.padA]) { item in
        haptic.observe(item,accepted:false,now:time)
        return false
    }
    #expect(failed.failedGroups == [a.id] && failed.pendingCleanup == [a.id])
    let survivor = haptic.snapshot(now:time)
    _ = mailbox.publish(snapshot:survivor,masterLevel:1,now:time)
    let rendered = mailbox.read(now:1.018)
    #expect(rendered?.frame == survivor.held && rendered?.frame?.tones.count == 1)
    let clean = output.retryCleanup(a.id,send:sink)
    #expect(clean && haptic.activeGroups == [b.id])
    haptic.stop()
    mailbox.close()
    #expect(haptic.frame() == nil && mailbox.retired)
}
