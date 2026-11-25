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
