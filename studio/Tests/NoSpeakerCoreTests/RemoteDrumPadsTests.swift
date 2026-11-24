import Foundation
import Testing
@testable import NoSpeakerCore

private func pads(_ seq: Int, _ mask: Int, version: Int = 4) -> Data {
    Data("{\"version\":\(version),\"sequence\":\(seq),\"kind\":\"drumPads\",\"mask\":\(mask)}".utf8)
}
private func pairedPads(_ runtime: inout PhysicalPatchRuntime, routes: [SensorMapping] = RemoteDrumPads.routes()) throws -> UUID {
    try runtime.configure(.init(routes: routes), allowRemote: true)
    let key = Data(repeating: 31,count: 32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1)
    return try runtime.admitRemote(secret:key,now:1)
}
private let kick = SensorDestination(.note,channel:9,number:36)
private let snare = SensorDestination(.note,channel:9,number:38)

@Test func remoteDrumPadsSnapshotMultiTouchAndRelease() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pairedPads(&runtime)
    let first = runtime.receiveRemote(id,bytes:pads(1,3),now:1.1)
    #expect(first == .accepted([.init(kick,value:100),.init(snare,value:100)]))
    let same = runtime.receiveRemote(id,bytes:pads(2,3),now:1.2)
    #expect(same == .accepted([]))
    let lift = runtime.receiveRemote(id,bytes:pads(3,2),now:1.3)
    #expect(lift == .accepted([.init(kick,value:0)]))
    let end = runtime.receiveRemote(id,bytes:pads(4,0),now:1.4)
    #expect(end == .accepted([.init(snare,value:0)]))
    #expect(runtime.remotePeerIDs.contains(id))
}

@Test func remoteDrumPadsSharedDestinationTransferDoesNotRetrigger() throws {
    var routes = RemoteDrumPads.routes()
    routes[1].destination = routes[0].destination
    var runtime = PhysicalPatchRuntime()
    let id = try pairedPads(&runtime,routes:routes)
    let first = runtime.receiveRemote(id,bytes:pads(1,1),now:1.1)
    #expect(first == .accepted([.init(kick,value:100)]))
    let transfer = runtime.receiveRemote(id,bytes:pads(2,2),now:1.2)
    #expect(transfer == .accepted([]))
    let end = runtime.receiveRemote(id,bytes:pads(3,0),now:1.3)
    #expect(end == .accepted([.init(kick,value:0)]))
}

@Test func remoteDrumPadsTimeoutAndUnmappedMaskFailClosed() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pairedPads(&runtime,routes:Array(RemoteDrumPads.routes().prefix(1)))
    _ = runtime.receiveRemote(id,bytes:pads(1,1),now:1.1)
    let bad = runtime.receiveRemote(id,bytes:pads(2,3),now:1.2)
    #expect(bad == .close([.init(kick,value:0)]))
    let token = Data(repeating: 32,count:32)
    try runtime.issueRemotePairing(secret:token,source:.phone,now:2)
    let next = try runtime.admitRemote(secret:token,now:2)
    _ = runtime.receiveRemote(next,bytes:pads(1,1),now:2.1)
    let stale = runtime.expire(now:2.5)
    #expect(stale == [.init(kick,value:0)])
    #expect(runtime.remotePeerIDs.isEmpty)
}

@Test func remoteDrumPadsStrictSchemaAndRoutePolicy() throws {
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pads(1,256)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pads(1,-1)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pads(1,1,version:3)) }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":4,\"sequence\":1,\"kind\":\"drumPads\",\"mask\":1,\"note\":60}".utf8))
    }
    var route = RemoteDrumPads.routes()[0]
    route.destination = .init(.controlChange,number:74)
    #expect(!InstrumentPatch(routes:[route]).isValid)
    route.destination = kick; route.calibration.inverted = true
    #expect(!InstrumentPatch(routes:[route]).isValid)
}
