import Foundation
import Testing
@testable import NoSpeakerCore

private func dynamicGroup(_ source:SensorSource,name:String) -> PerformanceInstrumentGroup {
    .init(name:name,patch:.init(routes:[
        .init(id:"note",source:source,signal:.padA,destination:.init(.note,channel:3,number:62)),
        .init(id:"other",source:source,signal:.padB,destination:.init(.note,channel:3,number:64)),
        .init(id:"pedal",source:source,signal:.padRT,destination:.init(.sustain,channel:3))
    ]))
}
private func dynamicSpec(_ cents:Int) -> PerformanceGroupTuningPlan.Specification {
    var scale = CustomScale()
    scale.centOffsets = [2:cents]
    return .init(scale:scale,root:60)
}

@Test func dynamicGroupDeliveryPreservesIndependentWireOwnershipAndFaultDebt() throws {
    let a = dynamicGroup(.gamepad1,name:"A"), b = dynamicGroup(.gamepad2,name:"B")
    var output = try DynamicMPEGroupDelivery(profile:.init(groups:[a,b]),tuning:[a.id:dynamicSpec(-20),b.id:dynamicSpec(20)])
    let prepared = output.prepare { _ in true }
    #expect(prepared && output.activeGroups == [a.id,b.id])
    let x = try output.connect(.gamepad1,now:1), y = try output.connect(.gamepad2,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    _ = output.frame(lease:x,sequence:1,now:1.01,values:[.padA:1,.padRT:1],send:sink)
    _ = output.frame(lease:y,sequence:1,now:1.01,values:[.padA:1],send:sink)
    let aOn = try #require(sent.first(where:{ $0.groupID == a.id && $0.command.destination.kind == .note }))
    sent.removeAll()
    let failed = output.frame(lease:x,sequence:2,now:1.02,values:[:],releasing:[.padA]) { item in
        sent.append(item);return false
    }
    #expect(failed.failedGroups == [a.id] && failed.pendingCleanup == [a.id])
    #expect(output.activeGroups == [b.id])
    #expect(sent.filter { $0.command.destination.kind == .note }.allSatisfy { $0.command.destination == aOn.command.destination })
    sent.removeAll()
    let wrong = output.retryCleanup(b.id,send:sink)
    #expect(wrong.pendingCleanup == [a.id] && sent.isEmpty)
    let recovered = output.retryCleanup(a.id,send:sink)
    #expect(recovered.pendingCleanup.isEmpty && sent.allSatisfy { $0.groupID == a.id })
    sent.removeAll()
    _ = output.frame(lease:y,sequence:2,now:1.03,values:[:],releasing:[.padA],send:sink)
    #expect(sent.count == 1 && sent.first?.groupID == b.id && sent.first?.command.value == 0)
}

@Test func dynamicGroupDeliverySetupFailureBlocksAllPortsAndNoFallback() throws {
    let a = dynamicGroup(.gamepad1,name:"A"), b = dynamicGroup(.gamepad2,name:"B")
    let profile = PerformanceGroupProfile(groups:[a,b])
    #expect(throws:MIDIClipError.invalidClip) {
        try DynamicMPEGroupDelivery(profile:profile,tuning:[a.id:dynamicSpec(20)])
    }
    var output = try DynamicMPEGroupDelivery(profile:profile,tuning:[a.id:dynamicSpec(20),b.id:dynamicSpec(-20)])
    var sent:[PerformanceGroupCommand] = []
    let ok = output.prepare { item in sent.append(item);return item.groupID != b.id }
    #expect(!ok && output.state == .retired && output.activeGroups.isEmpty)
    #expect(output.pendingCleanup == [b.id] && sent.allSatisfy { $0.command.destination.kind != .note })
    #expect(throws:PerformanceGroupTunedDelivery.AdmissionError.notReady) { try output.connect(.gamepad1,now:1) }
    sent.removeAll()
    let clean = output.retryCleanup(b.id) { sent.append($0);return true }
    #expect(clean.pendingCleanup.isEmpty && sent.allSatisfy { $0.groupID == b.id })
    let retry = output.prepare { _ in Issue.record("setup restarted");return true }
    #expect(!retry)
}


@Test func dynamicGroupCapacityDoesNotRetireGroupOrEmitUnallocatedNoteOffs() throws {
    let spec = dynamicSpec(20)
    let pitches = (36...83).filter { spec.scale.intervals.contains(($0-60+144)%12) }
    let wide = PerformanceInstrumentGroup(name:"Wide",patch:.init(routes:pitches.enumerated().map { i,note in
        .init(id:"n\(i)",source:.gamepad1,signal:.padA,destination:.init(.note,channel:3,number:note))
    }))
    let sibling = dynamicGroup(.gamepad2,name:"Sibling")
    var output = try DynamicMPEGroupDelivery(profile:.init(groups:[wide,sibling]),tuning:[wide.id:spec,sibling.id:spec])
    let prepared = output.prepare { _ in true }
    #expect(prepared)
    let x = try output.connect(.gamepad1,now:1), y = try output.connect(.gamepad2,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    let first = output.frame(lease:x,sequence:1,now:1.01,values:[.padA:1],send:sink)
    #expect(first.delivered == 15 && first.capacityRefused == 13 && first.failedGroups.isEmpty)
    let allocated = Set(sent.map(\.command.destination))
    #expect(allocated.count == 15)
    _ = output.frame(lease:y,sequence:1,now:1.02,values:[.padA:1],send:sink)
    sent.removeAll()
    let release = output.frame(lease:x,sequence:2,now:1.03,values:[:],releasing:[.padA],send:sink)
    #expect(release.delivered == 15 && release.capacityRefused == 0)
    #expect(Set(sent.map(\.command.destination)) == allocated && sent.allSatisfy { $0.groupID == wide.id && $0.command.value == 0 })
    #expect(output.activeGroups == [wide.id,sibling.id] && output.pendingCleanup.isEmpty)
    sent.removeAll()
    let next = output.frame(lease:x,sequence:3,now:1.04,values:[.padA:1],send:sink)
    #expect(next.delivered == 15 && next.capacityRefused == 13)
    sent.removeAll()
    _ = output.disconnectBatch([x,y],send:sink)
    #expect(sent.filter { $0.groupID == wide.id }.count == 15)
    #expect(sent.filter { $0.groupID == sibling.id }.count == 1)
    #expect(sent.allSatisfy { $0.command.value == 0 })
    #expect(output.sessionCount == 0 && output.pendingCleanup.isEmpty)
}
