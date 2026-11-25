import Foundation
import Testing
@testable import NoSpeakerCore

private func groupTuning(_ cents:Int) -> PerformanceGroupTuningPlan.Specification {
    var scale = CustomScale()
    scale.centOffsets = [2:cents]
    return .init(scale:scale,root:60)
}

private func tunedGroup(_ source:SensorSource,id:UUID = UUID(),channel:Int = 3) -> PerformanceInstrumentGroup {
    .init(id:id,name:source.rawValue,patch:.init(routes:[
        .init(id:"note",source:source,signal:.padA,destination:.init(.note,channel:channel,number:62)),
        .init(id:"other",source:source,signal:.padB,destination:.init(.note,channel:channel,number:64)),
        .init(id:"bend",source:source,signal:.padLSX,destination:.init(.pitchBend,channel:channel)),
        .init(id:"pedal",source:source,signal:.padRT,destination:.init(.sustain,channel:channel))
    ]))
}

@Test func groupTuningKeepsIndependentPortBendsAndStableNoteOffMembers() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    let standard = tunedGroup(.gamepad3)
    let profile = PerformanceGroupProfile(groups:[a,b,standard])
    let plan = try PerformanceGroupTuningPlan(profile:profile,tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    let za = try #require(plan.zones[a.id])
    let zb = try #require(plan.zones[b.id])
    #expect(za.members.map(\.channel) == [1,2])
    #expect(zb.members.map(\.channel) == [1,2])
    #expect(za.members[0].bend < 8192 && zb.members[0].bend > 8192)
    let note = SensorDestination(.note,channel:3,number:62)
    let on = try #require(plan.translate(.init(groupID:a.id,command:.init(note,value:100))))
    let off = try #require(plan.translate(.init(groupID:a.id,command:.init(note,value:0))))
    #expect(on.command.destination == off.command.destination)
    #expect(on.command.destination.channel == 1 && off.command.value == 0)
    let normal = PerformanceGroupCommand(groupID:standard.id,command:.init(note,value:100))
    #expect(plan.translate(normal) == normal)
    #expect(plan.translate(.init(groupID:a.id,command:.init(.init(.pitchBend,channel:3),value:10000))) ==
        .init(groupID:a.id,command:.init(.init(.pitchBend),value:10000)))
    #expect(plan.translate(.init(groupID:b.id,command:.init(.init(.sustain,channel:3),value:127))) ==
        .init(groupID:b.id,command:.init(.init(.sustain),value:127)))
    #expect(plan.translate(.init(groupID:a.id,command:.init(.init(.note,channel:3,number:63),value:80))) == nil)
    #expect(plan.translate(.init(groupID:UUID(),command:.init(note,value:100))) == nil)
}

@Test func groupTuningRejectsOffScaleCapacityMixedChannelAndUnsafeEffects() throws {
    var group = tunedGroup(.gamepad1)
    let spec = groupTuning(-20)
    group.patch.routes[0].destination.number = 61
    #expect(throws:MIDIClipError.invalidNote) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes[1].destination.channel = 2
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes.append(.init(id:"setup",source:.gamepad1,signal:.padLT,destination:.init(.controlChange,channel:3,number:6)))
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes = (0..<16).map { index in
        .init(id:"n"+String(index),source:.gamepad1,signal:.padA,
              destination:.init(.note,channel:3,number:36+(index/7)*12+[0,2,4,5,7,9,11][index%7]))
    }
    #expect(throws:MIDIClipError.tuningCapacity) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
}

@Test func groupTunedDeliverySetupBeforeNotesAndScopedPanicPreserveMemberBends() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a,b]),
        tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    #expect(throws:PerformanceGroupTunedDelivery.AdmissionError.notReady) {
        try session.connect(.gamepad1,now:0)
    }
    var wire: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand)->Bool = { wire.append($0); return true }
    let prepared = session.prepare(send:sink)
    #expect(prepared && session.state == .ready && session.pendingCleanup.isEmpty)
    #expect(wire.allSatisfy { $0.command.destination.kind != .note })
    #expect(Set(wire.map(\.groupID)) == [a.id,b.id])
    wire.removeAll()
    let x = try session.connect(.gamepad1,now:0)
    let y = try session.connect(.gamepad2,now:0)
    _ = session.frame(lease:x,sequence:1,now:0.01,values:[.padA:1,.padRT:1],send:sink)
    _ = session.frame(lease:y,sequence:1,now:0.01,values:[.padA:1],send:sink)
    #expect(wire.filter { $0.command.destination.kind == .note }.map { $0.command.destination.channel } == [1,1])
    wire.removeAll()
    _ = session.stopGroup(a.id,send:sink)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == a.id && $0.command.value == 0 })
    wire.removeAll()
    _ = session.panic(send:sink)
    #expect(wire.count == 1 && wire[0].groupID == b.id && wire[0].command.destination.channel == 1 && wire[0].command.value == 0)
    #expect(session.pendingCleanup.isEmpty && session.state == .retired)
}

@Test func groupTunedSetupFailureRetainsOriginalPortSelectorDebtAndBlocksAllNotes() throws {
    let a = tunedGroup(.gamepad1,id:try #require(UUID(uuidString:"00000000-0000-0000-0000-000000000001")))
    let b = tunedGroup(.gamepad2,id:try #require(UUID(uuidString:"00000000-0000-0000-0000-000000000002")))
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a,b]),
        tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    var wire: [PerformanceGroupCommand] = []
    let prepared = session.prepare { item in
        wire.append(item)
        return item.groupID != b.id
    }
    #expect(!prepared && session.state == .retired && session.pendingCleanup == [b.id])
    #expect(throws:PerformanceGroupTunedDelivery.AdmissionError.notReady) {
        try session.connect(.gamepad1,now:0)
    }
    wire.removeAll()
    let wrong = session.retryCleanup(a.id) { wire.append($0); return true }
    #expect(wrong && wire.isEmpty && session.pendingCleanup == [b.id])
    let recovered = session.retryCleanup(b.id) { wire.append($0); return true }
    #expect(recovered && session.pendingCleanup.isEmpty)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == b.id && $0.command.value == 127 })
    let again = session.prepare { _ in true }
    #expect(!again && session.state == .retired)
}

@Test func groupTunedFailedNoteReleaseRetriesSameMemberOnly() throws {
    let a = tunedGroup(.gamepad1)
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a]),tuning:[a.id:groupTuning(-20)])
    let ready = session.prepare { _ in true }
    #expect(ready)
    let lease = try session.connect(.gamepad1,now:0)
    _ = session.frame(lease:lease,sequence:1,now:0.01,values:[.padA:1],send:{ _ in true })
    _ = session.disconnect(lease,send:{ _ in false })
    #expect(session.pendingCleanup == [a.id])
    var wire: [PerformanceGroupCommand] = []
    let clean = session.retryCleanup(a.id) { wire.append($0); return true }
    #expect(clean && session.pendingCleanup.isEmpty)
    #expect(wire == [.init(groupID:a.id,command:.init(.init(.note,channel:1,number:62),value:0))])
}
