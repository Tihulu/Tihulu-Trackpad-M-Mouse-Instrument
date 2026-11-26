import Foundation
import Testing
@testable import NoSpeakerCore

private let bridgeNote = SensorDestination(.note, number: 60)
private let bridgeSecret = Data(repeating: 7, count: 32)
private let bridgeTouch = Data("{\"version\":1,\"sequence\":1,\"kind\":\"touch\",\"x\":0.2,\"y\":0.8}".utf8)
private func bridgeRuntime() throws -> PhysicalPatchRuntime {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes: [
        .init(id: "remote", source: .phone, signal: .contact, destination: bridgeNote),
        .init(id: "local", source: .trackpad, signal: .contact, destination: bridgeNote)
    ]), allowRemote: true)
    return runtime
}

@Test func bridgeAdmissionMapsOnlyHostConnectionAndRevokes() throws {
    var runtime = try bridgeRuntime()
    var bridge = RemoteHostBridge()
    let id = UUID()
    #expect(throws: RemoteTouchError.unavailable) {
        try bridge.issue(secret: bridgeSecret, source: .phone, now: 1, runtime: &runtime)
    }
    _ = bridge.process([.ready], now: 1, runtime: &runtime)
    try bridge.issue(secret: bridgeSecret, source: .phone, now: 1, runtime: &runtime)
    let admission = bridge.process([.invitation(id, bridgeSecret, 1.01)], now: 1.02, runtime: &runtime)
    #expect(admission.actions == [.acknowledge(id,true)])
    let unknown = UUID()
    let rejected = bridge.process([.frame(unknown, bridgeTouch, 1.03)], now: 1.04, runtime: &runtime)
    #expect(rejected.commands.isEmpty && rejected.actions == [.acknowledge(unknown,false)])
    let played = bridge.process([.frame(id, bridgeTouch, 1.05)], now: 1.06, runtime: &runtime)
    #expect(played.commands == [.init(bridgeNote,value:100)])
    let released = bridge.revoke(id, runtime: &runtime)
    #expect(released.commands == [.init(bridgeNote,value:0)])
    #expect(bridge.connectionIDs.isEmpty)
}

@Test func bridgeDiscardDisconnectedAndStaleQueuedFrames() throws {
    var runtime = try bridgeRuntime()
    var bridge = RemoteHostBridge()
    _ = bridge.process([.ready], now: 1, runtime: &runtime)
    let id = UUID()
    try bridge.issue(secret: bridgeSecret, source: .phone, now: 1, runtime: &runtime)
    _ = bridge.process([.invitation(id, bridgeSecret, 1)], now: 1, runtime: &runtime)
    let disconnected = bridge.process([.frame(id, bridgeTouch, 1.1), .disconnected(id)], now: 1.11, runtime: &runtime)
    #expect(disconnected.commands.isEmpty && bridge.connectionIDs.isEmpty)
    try bridge.issue(secret: bridgeSecret, source: .phone, now: 2, runtime: &runtime)
    _ = bridge.process([.invitation(id, bridgeSecret, 2)], now: 2, runtime: &runtime)
    let stale = bridge.process([.frame(id, bridgeTouch, 2.01)], now: 2.2, runtime: &runtime)
    #expect(stale.commands.isEmpty && stale.actions == [.acknowledge(id,false)])
}

@Test func bridgeExpiryAndFaultPreserveLocalOwnershipAndFenceFutureEvents() throws {
    var runtime = try bridgeRuntime()
    var bridge = RemoteHostBridge()
    _ = bridge.process([.ready], now: 1, runtime: &runtime)
    let id = UUID()
    try bridge.issue(secret: bridgeSecret, source: .phone, now: 1, runtime: &runtime)
    _ = bridge.process([.invitation(id, bridgeSecret, 1)], now: 1, runtime: &runtime)
    _ = bridge.process([.frame(id, bridgeTouch, 1.1)], now: 1.1, runtime: &runtime)
    _ = runtime.receive(source: .trackpad, x: 0.2, y: 0.8, size: 0.4, hostTime: 1.4, now: 1.4)
    let expired = bridge.process([], now: 1.5, runtime: &runtime)
    #expect(expired.commands.isEmpty && expired.actions == [.revoke(id)])
    let fault = bridge.process([.fault], now: 1.51, runtime: &runtime)
    #expect(fault.fault && fault.actions == [.stop] && fault.commands.isEmpty)
    let late = bridge.process([.ready,.invitation(id,bridgeSecret,1.52)], now: 1.52, runtime: &runtime)
    #expect(late.commands.isEmpty && late.actions.isEmpty && bridge.stopped)
    let localRelease = runtime.receive(source: .trackpad, x: nil,y:nil,size:nil,hostTime:1.53,now:1.53)
    #expect(localRelease == [.init(bridgeNote,value:0)])
}

@Test func builderRemoteBatchRetainsOldestCommandProducingReceipt() throws {
    var runtime=try bridgeRuntime()
    var bridge=RemoteHostBridge()
    let id=UUID()
    _=bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.phone,now:1,runtime:&runtime)
    let paired=bridge.process([.invitation(id,bridgeSecret,1)],now:1,runtime:&runtime)
    #expect(paired.deliveryReceipt==nil)
    let release=Data("{\"version\":1,\"sequence\":2,\"kind\":\"release\"}".utf8)
    let batch=bridge.process([.frame(id,bridgeTouch,1.01),.frame(id,release,1.03)],now:1.04,runtime:&runtime)
    #expect(batch.deliveryReceipt==1.01)
    #expect(batch.commands.first == .init(bridgeNote,value:100))
    var fence=batch.deliveryReceipt.map { PhysicalReceiptSendFence(receipt:$0,maximumAge:0.1) }
    var ledger=PatchOutputLedger()
    var now=1.04
    var sent:[SensorCommand]=[]
    let result=PhysicalReceiptCommandBatch.dispatch(batch.commands,fence:&fence,now:{now},send:{cmd in
        ledger.deliver(cmd,send:{sent.append($0);now=1.11;return true})
    })
    #expect(result == .expired)
    #expect(sent == [.init(bridgeNote,value:100)])
    let clean=ledger.releaseAll(send:{sent.append($0);return true})
    #expect(clean && sent == [.init(bridgeNote,value:100),.init(bridgeNote,value:0)])
}

@Test func builderRemoteDisconnectCleanupHasNoNewReceipt() throws {
    var runtime=try bridgeRuntime()
    var bridge=RemoteHostBridge()
    let id=UUID()
    _=bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.phone,now:1,runtime:&runtime)
    _=bridge.process([.invitation(id,bridgeSecret,1)],now:1,runtime:&runtime)
    _=bridge.process([.frame(id,bridgeTouch,1.02)],now:1.03,runtime:&runtime)
    let release=bridge.process([.disconnected(id)],now:1.04,runtime:&runtime)
    #expect(release.deliveryReceipt==nil && release.commands == [.init(bridgeNote,value:0)])
}


@Test func builderRemoteRejectsSameBatchReinvitationAndPreIssueReceipt() throws {
    var runtime=try bridgeRuntime()
    var bridge=RemoteHostBridge()
    let id=UUID()
    _=bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.phone,now:1,runtime:&runtime)
    let stale=bridge.process([.invitation(id,bridgeSecret,0.99)],now:1.01,runtime:&runtime)
    #expect(stale.actions == [.acknowledge(id,false)] && bridge.connectionIDs.isEmpty)
    let other=UUID()
    let rejected=bridge.process([.frame(other,bridgeTouch,1.02),.invitation(other,bridgeSecret,1.02),
                                 .frame(other,bridgeTouch,1.02)],now:1.02,runtime:&runtime)
    #expect(rejected.actions == [.acknowledge(other,false),.acknowledge(other,false),.acknowledge(other,false)])
    #expect(rejected.commands.isEmpty && bridge.connectionIDs.isEmpty)
    let fresh=UUID()
    #expect(bridge.process([.invitation(fresh,bridgeSecret,1.03)],now:1.03,runtime:&runtime).actions == [.acknowledge(fresh,true)])
}

@Test func builderRemoteSuppressesMetadataQueuedBeforeRejection() throws {
    var runtime=try bridgeRuntime()
    var bridge=RemoteHostBridge()
    let id=UUID()
    _=bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.phone,now:1,runtime:&runtime)
    _=bridge.process([.invitation(id,bridgeSecret,1)],now:1,runtime:&runtime)
    let capabilities=Data("{\"version\":7,\"sequence\":1,\"kind\":\"capabilities\"}".utf8)
    let result=bridge.process([.frame(id,capabilities,1.01),.frame(id,Data([0xff]),1.01)],now:1.01,runtime:&runtime)
    #expect(result.actions == [.acknowledge(id,false)] && result.commands.isEmpty)
    #expect(bridge.connectionIDs.isEmpty && runtime.remotePeerIDs.isEmpty)
}

@Test func builderRemoteSimultaneousDeparturesDoNotRestoreDyingContinuousOwner() throws {
    var runtime=PhysicalPatchRuntime()
    let target=SensorDestination(.controlChange,number:74)
    try runtime.configure(.init(routes:[
        .init(id:"high",source:.phone,signal:.x,destination:target,priority:10),
        .init(id:"low",source:.tablet,signal:.x,destination:target,priority:0)
    ]),allowRemote:true)
    var bridge=RemoteHostBridge()
    let a=UUID(),b=UUID()
    _=bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.phone,now:1,runtime:&runtime)
    _=bridge.process([.invitation(a,bridgeSecret,1)],now:1,runtime:&runtime)
    try bridge.issue(secret:bridgeSecret,source:.tablet,now:1,runtime:&runtime)
    _=bridge.process([.invitation(b,bridgeSecret,1)],now:1,runtime:&runtime)
    let high=Data("{\"version\":1,\"sequence\":1,\"kind\":\"touch\",\"x\":0.8,\"y\":0.5}".utf8)
    let low=Data("{\"version\":1,\"sequence\":1,\"kind\":\"touch\",\"x\":0.3,\"y\":0.5}".utf8)
    _=bridge.process([.frame(a,high,1.01)],now:1.01,runtime:&runtime)
    _=bridge.process([.frame(b,low,1.2)],now:1.2,runtime:&runtime)
    let result=bridge.process([.disconnected(b)],now:1.37,runtime:&runtime)
    #expect(result.commands == [.init(target,value:0)])
    #expect(result.actions == [.revoke(a)] && bridge.connectionIDs.isEmpty)
}
