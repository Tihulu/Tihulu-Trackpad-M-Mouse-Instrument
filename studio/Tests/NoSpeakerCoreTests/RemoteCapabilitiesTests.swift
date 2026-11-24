import Foundation
import Testing
@testable import NoSpeakerCore

private func capabilityQuery(_ sequence: Int = 1) -> Data {
    Data("{\"version\":7,\"sequence\":\(sequence),\"kind\":\"capabilities\"}".utf8)
}
private let capabilityKey = Data(repeating: 79,count:32)
private func capabilityRuntime() throws -> PhysicalPatchRuntime {
    var runtime = PhysicalPatchRuntime()
    let routes = Array(RemoteDrumPads.routes().prefix(2)) +
        Array(RemotePiano.routes(source:.tablet).prefix(1)) +
        [AirDrumPreset.snare.route(), .init(id:"tilt",source:.phone,signal:.tiltPitch,destination:.init(.controlChange,number:74))]
    try runtime.configure(.init(routes:routes),allowRemote:true)
    return runtime
}
@Test func capabilitiesBoundToAuthenticatedSource() throws {
    var runtime = try capabilityRuntime()
    var bridge = RemoteHostBridge()
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    let phone = UUID(), tablet = UUID()
    try bridge.issue(secret:capabilityKey,source:.phone,now:1,runtime:&runtime)
    _ = bridge.process([.invitation(phone,capabilityKey,1)],now:1,runtime:&runtime)
    let manifest = bridge.process([.frame(phone,capabilityQuery(),1.1)],now:1.1,runtime:&runtime)
    #expect(manifest.commands.isEmpty)
    #expect(manifest.actions == [.capabilities(phone,.init(touch:false,tilt:true,acceleration:true,rotation:false,airDrums:true,drums:3,piano:0,pedals:0))])
    try bridge.issue(secret:capabilityKey,source:.tablet,now:1.2,runtime:&runtime)
    _ = bridge.process([.invitation(tablet,capabilityKey,1.2)],now:1.2,runtime:&runtime)
    let other = bridge.process([.frame(tablet,capabilityQuery(),1.3)],now:1.3,runtime:&runtime)
    #expect(other.actions == [.capabilities(tablet,.init(touch:false,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:0,piano:1,pedals:0))])
}
@Test func capabilitiesRejectUnknownPeerAndReplay() throws {
    var runtime = try capabilityRuntime()
    var bridge = RemoteHostBridge()
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    let id = UUID()
    let denied = bridge.process([.frame(id,capabilityQuery(),1.1)],now:1.1,runtime:&runtime)
    #expect(denied.actions == [.acknowledge(id,false)])
    try bridge.issue(secret:capabilityKey,source:.phone,now:1.2,runtime:&runtime)
    _ = bridge.process([.invitation(id,capabilityKey,1.2)],now:1.2,runtime:&runtime)
    _ = bridge.process([.frame(id,capabilityQuery(),1.3)],now:1.3,runtime:&runtime)
    let replay = bridge.process([.frame(id,capabilityQuery(),1.4)],now:1.4,runtime:&runtime)
    #expect(replay.actions == [.acknowledge(id,false)])
    #expect(bridge.connectionIDs.isEmpty)
}
@Test func capabilitiesQueryCannotRefreshActivePad() throws {
    var runtime = try capabilityRuntime()
    try runtime.issueRemotePairing(secret:capabilityKey,source:.phone,now:1)
    let id = try runtime.admitRemote(secret:capabilityKey,now:1)
    let pad = Data("{\"version\":4,\"sequence\":1,\"kind\":\"drumPads\",\"mask\":1}".utf8)
    _ = runtime.receiveRemote(id,bytes:pad,now:1.1)
    let rejected = runtime.receiveRemote(id,bytes:capabilityQuery(2),now:1.2)
    #expect(rejected == .close([.init(.init(.note,channel:9,number:36),value:0)]))
    #expect(runtime.remoteCapabilities(id) == nil)
}
@Test func capabilitiesSchemaAndBoundedResponse() throws {
    let maximal = RemoteCapabilities(touch:true,tilt:true,acceleration:true,rotation:true,airDrums:true,drums:255,piano:RemotePiano.maximumMask,pedals:63)
    let encoded = try maximal.encoded()
    #expect(encoded.count <= RemoteTouchFrame.maximumBytes)
    let object = try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
    #expect(Set(object.keys) == ["kind","version","touch","tilt","acceleration","rotation","airDrums","drums","piano","pedals"])
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":7,\"sequence\":1,\"kind\":\"capabilities\",\"source\":\"tablet\"}".utf8))
    }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteCapabilities(touch:false,tilt:false,acceleration:false,rotation:false,airDrums:true,drums:0,piano:0,pedals:0).encoded()
    }
}
