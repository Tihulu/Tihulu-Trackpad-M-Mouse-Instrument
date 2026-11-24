import Foundation
import Testing
@testable import NoSpeakerCore

private func mappingFixture() -> InstrumentPatch {
    .init(name:"Private patch name",routes:[
        .init(id:"private-route",source:.phone,signal:.contact,destination:.init(.note,channel:2,number:70)),
        .init(id:"fanout-a",source:.phone,signal:.contact,destination:.init(.note,channel:2,number:70)),
        .init(id:"fanout-b",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"tablet",source:.tablet,signal:.drumPad1,destination:.init(.note,channel:9,number:38)),
        .init(id:"local",source:.trackpad,signal:.x,destination:.init(.controlChange,number:74))
    ])
}
@Test func mappingProjectionIsSourceBoundSortedAndGrouped() throws {
    let projection = try RemoteMappingProjection(patch:mappingFixture(),source:.phone)
    #expect(projection.rows == [[2,0,0,60,1],[2,0,2,70,2]])
    let page = try projection.page(0,sequence:2,detail:true)
    #expect(page.total == 2)
    let encoded = try page.encoded()
    #expect(encoded.count <= 256)
    #expect(!String(decoding:encoded,as:UTF8.self).contains("private"))
    let tablet = try RemoteMappingProjection(patch:mappingFixture(),source:.tablet)
    #expect(tablet.rows == [[9,0,9,38,1]])
    #expect(throws:RemoteTouchError.invalidFrame) { try RemoteMappingProjection(patch:mappingFixture(),source:.trackpad) }
}
@Test func mappingConsentDefaultsOffAndIsBoundToInvitation() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(mappingFixture(),allowRemote:true)
    let key = Data(repeating:83,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1,mappingDetails:true)
    let visible = try runtime.admitRemote(secret:key,now:1)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1.1)
    let hidden = try runtime.admitRemote(secret:key,now:1.1)
    let detail = try runtime.remoteMappingPage(visible,page:0,sequence:2)
    let withheld = try runtime.remoteMappingPage(hidden,page:0,sequence:2)
    #expect(detail.detail && detail.total == 2)
    #expect(!withheld.detail && withheld.total == 0 && withheld.rows.isEmpty && withheld.pages == 1)
    #expect(throws:RemoteTouchError.invalidFrame) { try runtime.remoteMappingPage(hidden,page:1,sequence:3) }
    let touch = Data(#"{"version":1,"sequence":1,"kind":"touch","x":0.5,"y":0.5}"#.utf8)
    _ = runtime.receiveRemote(visible,bytes:touch,now:1.2)
    #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingPage(visible,page:0,sequence:2) }
    _ = runtime.revokeRemote(visible)
    #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingPage(visible,page:0,sequence:2) }
    #expect(try runtime.remoteMappingPage(hidden,page:0,sequence:2).detail == false)
}
@Test func mappingProjectionPaginatesMaximumRoutesWithinWireLimit() throws {
    let routes = (0..<64).map { i in
        SensorMapping(id:"route-\(i)",source:.phone,signal:.contact,destination:.init(.note,channel:15,number:64+i))
    }
    let projection = try RemoteMappingProjection(patch:.init(routes:routes),source:.phone)
    #expect(projection.rows.count == 64)
    var collected: [[Int]] = []
    for i in 0..<8 {
        let page = try projection.page(i,sequence:9_007_199_254_740_991,detail:true)
        #expect(page.pages == 8 && page.total == 64 && page.rows.count == 8)
        #expect(try page.encoded().count <= 256)
        collected += page.rows
    }
    #expect(collected == projection.rows)
    #expect(throws:RemoteTouchError.invalidFrame) { try projection.page(8,sequence:1,detail:true) }
}


@Test func mappingConsentCancelledExpiredAndReplacedInvitationDoesNotLeak() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(mappingFixture(),allowRemote:true)
    let old = Data(repeating:51,count:32), fresh = Data(repeating:52,count:32)
    try runtime.issueRemotePairing(secret:old,source:.phone,now:1,mappingDetails:true)
    runtime.cancelRemotePairing()
    #expect(throws:RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret:old,now:1.1) }
    try runtime.issueRemotePairing(secret:old,source:.phone,now:2,mappingDetails:true)
    #expect(throws:RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret:old,now:62) }
    try runtime.issueRemotePairing(secret:old,source:.phone,now:63,mappingDetails:true)
    try runtime.issueRemotePairing(secret:fresh,source:.tablet,now:63.1)
    #expect(throws:RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret:old,now:63.2) }
    let peer = try runtime.admitRemote(secret:fresh,now:63.3)
    let page = try runtime.remoteMappingPage(peer,page:0,sequence:2)
    #expect(!page.detail && page.rows.isEmpty && page.total == 0)
    #expect(runtime.remoteCapabilities(peer)?.drums == 1)
}

@Test func mappingConsentBridgeDefaultAndExplicitAreSeparate() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(mappingFixture(),allowRemote:true)
    var bridge = RemoteHostBridge()
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    let key = Data(repeating:41,count:32)
    let first = UUID(), second = UUID()
    try bridge.issue(secret:key,source:.phone,now:1,runtime:&runtime,mappingDetails:true)
    _ = bridge.process([.invitation(first,key,1)],now:1,runtime:&runtime)
    try bridge.issue(secret:key,source:.phone,now:1.1,runtime:&runtime)
    _ = bridge.process([.invitation(second,key,1.1)],now:1.1,runtime:&runtime)
    let caps = Data(#"{"version":7,"sequence":1,"kind":"capabilities"}"#.utf8)
    let query = Data(#"{"version":8,"sequence":2,"kind":"mapping","page":0}"#.utf8)
    _ = bridge.process([.frame(first,caps,1.2),.frame(second,caps,1.2)],now:1.2,runtime:&runtime)
    let result = bridge.process([.frame(first,query,1.3),.frame(second,query,1.3)],now:1.3,runtime:&runtime)
    #expect(result.commands.isEmpty)
    #expect(result.actions.count == 2)
    if case .mapping(let id,let page) = result.actions.first {
        #expect(id == first && page.detail && page.total == 2)
    } else { Issue.record("Expected explicit detail response") }
    if case .mapping(let id,let page) = result.actions.last {
        #expect(id == second && !page.detail && page.total == 0 && page.rows.isEmpty)
    } else { Issue.record("Expected withheld response") }
    _ = bridge.revoke(first,runtime:&runtime)
    #expect(bridge.connectionIDs == [second])
}

@Test func hybridRemoteProjectionAndProbeRemainSourceScoped() throws {
    var patch = mappingFixture()
    patch.routes.append(.init(id:"synthetic-private",source:.external,signal:.x,destination:.init(.pitchBend)))
    #expect(throws:RemoteTouchError.invalidFrame) { try RemoteMappingProjection(patch:patch,source:.phone) }
    let projection = try RemoteMappingProjection(patch:patch,source:.phone,synthetic:.external)
    #expect(projection.rows == [[2,0,0,60,1],[2,0,2,70,2]])
    let probe = try RemoteProbeContract.expected(patch:patch,source:.phone,synthetic:.external)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true,synthetic:.external)
    let key = Data(repeating:42,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1,mappingDetails:true)
    let peer = try runtime.admitRemote(secret:key,now:1)
    #expect(runtime.remoteCapabilities(peer) == probe)
    let page = try runtime.remoteMappingPage(peer,page:0,sequence:2)
    #expect(page.rows == projection.rows)
    #expect(throws:RemoteTouchError.unavailable) { try RemoteProbeContract.expected(patch:patch,source:.external,synthetic:.external) }
}
