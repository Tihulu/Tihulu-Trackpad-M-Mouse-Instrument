import Foundation
import Testing
@testable import NoSpeakerCore

private func dynamicHapticFixture() throws -> (PerformanceGroupProfile,DynamicMPEPreview,UUID,UUID) {
    let a = PerformanceInstrumentGroup(name:"Wide",patch:.init(routes:[
        .init(id:"a",source:.gamepad1,signal:.padA,destination:.init(.note,channel:3,number:62)),
        .init(id:"b",source:.gamepad1,signal:.padB,destination:.init(.note,channel:3,number:74)),
        .init(id:"c",source:.gamepad1,signal:.padX,destination:.init(.note,channel:3,number:64)),
        .init(id:"pedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain,channel:3))
    ]))
    let b = PerformanceInstrumentGroup(name:"Sibling",patch:.init(routes:[
        .init(id:"note",source:.gamepad2,signal:.padA,destination:.init(.note,channel:3,number:62))
    ]))
    let spec = try DynamicMPEPreview.specification(name:"Custom",degrees:"0, 220, 400, 500, 700, 900, 1100",rootText:"60")
    let other = try DynamicMPEPreview.specification(name:"Custom other",degrees:"0, 180, 400, 500, 700, 900, 1100",rootText:"60")
    let profile = PerformanceGroupProfile(groups:[a,b])
    let preview = try DynamicMPEPreview(profile:profile,tuning:[a.id:spec,b.id:other])
    return (profile,preview,a.id,b.id)
}

@Test func dynamicHapticProjectionUsesActualReallocatedWireMemberAndSustain() throws {
    let (profile,preview,a,b) = try dynamicHapticFixture()
    var output = try DynamicMPEGroupDelivery(profile:profile,tuning:preview.tuning)
    let ready = output.prepare { _ in true }
    #expect(ready)
    var projection = try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:[a,b])
    let x = try output.connect(.gamepad1,now:1)
    let y = try output.connect(.gamepad2,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { item in
        sent.append(item)
        projection.observe(item,accepted:true)
        return true
    }
    _ = output.frame(lease:x,sequence:1,now:1.01,values:[.padA:1,.padRT:1],send:sink)
    _ = output.frame(lease:x,sequence:2,now:1.02,values:[:],releasing:[.padA],send:sink)
    _ = output.frame(lease:x,sequence:3,now:1.03,values:[.padB:1],send:sink)
    let attacks = sent.filter { $0.groupID == a && $0.command.destination.kind == .note && $0.command.value > 0 }
    #expect(attacks.count == 2)
    #expect(attacks[0].command.destination.channel != attacks[1].command.destination.channel)
    _ = output.frame(lease:y,sequence:1,now:1.04,values:[.padA:1],send:sink)
    #expect(projection.frame()?.tones.count == 3)
    _ = output.frame(lease:x,sequence:4,now:1.05,values:[:],releasing:[.padB,.padRT],send:sink)
    #expect(projection.frame()?.tones.count == 1)
    _ = output.frame(lease:x,sequence:5,now:1.06,values:[.padB:1],send:sink)
    let reused = try #require(sent.last)
    #expect(reused.command.destination.channel == attacks[0].command.destination.channel)
    let plan = try #require(preview.groups.first(where: { $0.id == a })?.plan)
    let member = try #require(plan.members.first(where: { $0.channel == reused.command.destination.channel }))
    let expected = try MusicTheory.frequency(midi:74)*pow(2,Double(member.bend-8192)/8192*2/12)
    #expect(projection.frame()?.tones.contains { abs($0.frequencyHz-expected) < 0.001 } == true)
    _ = output.disconnectBatch([x,y],send:sink)
    #expect(projection.frame() == nil)
}

@Test func dynamicHapticProjectionRejectsWrongBendMemberAndSetupTargets() throws {
    let (_,preview,a,b) = try dynamicHapticFixture()
    var projection = try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:[a,b])
    let group = try #require(preview.groups.first(where:{ $0.id == a }))
    let wrong = try #require(group.routes.first(where:{ $0.logical.number == 64 && $0.logical.kind == .note })?.possibleChannels.first)
    projection.observe(.init(groupID:a,command:.init(.init(.note,channel:wrong-1,number:62),value:100)),accepted:true)
    #expect(projection.activeGroups == [b] && projection.frame() == nil)
    projection.observe(.init(groupID:b,command:.init(.init(.controlChange,channel:0,number:101),value:0)),accepted:true)
    #expect(projection.activeGroups.isEmpty)
    #expect(throws:PerformanceGroupHapticProjection.AdmissionError.invalidSelection) {
        try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:[UUID()])
    }
}


@Test func dynamicHapticCapacityRefusedNotesNeverReachProjection() throws {
    let spec = try DynamicMPEPreview.specification(name:"Wide",degrees:"0, 220, 400, 500, 700, 900, 1100",rootText:"60")
    let pitches = (36...83).filter { spec.scale.intervals.contains(($0-60+144)%12) }
    let group = PerformanceInstrumentGroup(name:"Wide",patch:.init(routes:pitches.enumerated().map { i,note in
        .init(id:"n\(i)",source:.gamepad1,signal:.padA,destination:.init(.note,channel:3,number:note))
    }))
    let profile = PerformanceGroupProfile(groups:[group])
    let preview = try DynamicMPEPreview(profile:profile,tuning:[group.id:spec])
    var output = try DynamicMPEGroupDelivery(profile:profile,tuning:preview.tuning)
    let ready = output.prepare { _ in true }
    #expect(ready)
    var projection = try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:[group.id])
    let lease = try output.connect(.gamepad1,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { item in
        sent.append(item)
        projection.observe(item,accepted:true)
        return true
    }
    let report = output.frame(lease:lease,sequence:1,now:1.01,values:[.padA:1],send:sink)
    #expect(report.delivered == 15 && report.capacityRefused == 13)
    #expect(sent.count == 15 && projection.activeGroups == [group.id])
    let frame = try #require(projection.frame())
    #expect(frame.tones.count <= 6)
    let allocated = Set(sent.map(\.command.destination))
    sent.removeAll()
    let held = output.frame(lease:lease,sequence:2,now:1.02,values:[.padA:1],send:sink)
    #expect(held.delivered == 0 && held.capacityRefused == 0 && sent.isEmpty)
    #expect(projection.frame() == frame)
    let release = output.frame(lease:lease,sequence:3,now:1.03,values:[:],releasing:[.padA],send:sink)
    #expect(release.delivered == 15 && Set(sent.map(\.command.destination)) == allocated)
    #expect(sent.allSatisfy { $0.command.value == 0 } && projection.frame() == nil)
}

@Test func dynamicHapticTransportFailureRetiresOnlyFailedGroup() throws {
    let (profile,preview,a,b) = try dynamicHapticFixture()
    var output = try DynamicMPEGroupDelivery(profile:profile,tuning:preview.tuning)
    _ = output.prepare { _ in true }
    var projection = try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:[a,b])
    let x = try output.connect(.gamepad1,now:1)
    let y = try output.connect(.gamepad2,now:1)
    let sink:(PerformanceGroupCommand)->Bool = { item in
        projection.observe(item,accepted:true)
        return true
    }
    _ = output.frame(lease:x,sequence:1,now:1.01,values:[.padA:1],send:sink)
    _ = output.frame(lease:y,sequence:1,now:1.02,values:[.padA:1],send:sink)
    let report = output.frame(lease:x,sequence:2,now:1.03,values:[:],releasing:[.padA]) { item in
        projection.observe(item,accepted:false)
        return false
    }
    #expect(report.failedGroups == [a] && report.pendingCleanup == [a])
    #expect(projection.activeGroups == [b] && projection.frame()?.tones.count == 1)
    let clean = output.retryCleanup(a,send:sink)
    #expect(clean.pendingCleanup.isEmpty && projection.activeGroups == [b])
    _ = output.disconnectBatch([y],send:sink)
    #expect(projection.frame() == nil)
}
