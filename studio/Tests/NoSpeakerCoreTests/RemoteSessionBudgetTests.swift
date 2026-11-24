import Foundation
import Testing
@testable import NoSpeakerCore

private func capacityRoutes(_ source: SensorSource, all: Bool) -> [SensorMapping] {
    let routes: [SensorMapping] = [
        .init(id:"\(source.rawValue)-touch",source:source,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"\(source.rawValue)-tilt",source:source,signal:.tiltPitch,destination:.init(.controlChange,number:74)),
        .init(id:"\(source.rawValue)-accel",source:source,signal:.accelerationMagnitude,destination:.init(.controlChange,number:75)),
        .init(id:"\(source.rawValue)-rotation",source:source,signal:.rotationMagnitude,destination:.init(.controlChange,number:76))
    ]
    if !all { return routes }
    return routes + Array(RemoteDrumPads.routes(source:source).prefix(1)) +
        Array(RemotePiano.routes(source:source).prefix(1)) + Array(RemotePedalboard.routes(source:source).prefix(1))
}
private func capacityPair(_ runtime: inout PhysicalPatchRuntime, _ source: SensorSource, _ now: Double) throws -> UUID {
    let key = Data(repeating:42,count:32)
    try runtime.issueRemotePairing(secret:key,source:source,now:now)
    return try runtime.admitRemote(secret:key,now:now)
}
@Test func remoteReservationsProtectLocalBudgetAndExistingPeers() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true) + capacityRoutes(.tablet,all:false) +
        [.init(id:"local",source:.trackpad,signal:.contact,destination:.init(.note,number:62))]),allowRemote:true)
    let phone = try capacityPair(&runtime,.phone,1)
    let tablet = try capacityPair(&runtime,.tablet,1.1)
    #expect(runtime.reservedRemoteSessions == 11)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.phone,1.2) }
    #expect(runtime.remotePeerIDs == [phone,tablet])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2) == [.init(.init(.note,number:62),value:100)])
    let release = Data(#"{"version":1,"sequence":1,"kind":"release"}"#.utf8)
    #expect(runtime.receiveRemote(phone,bytes:release,now:1.3) == .accepted([]))
    #expect(runtime.reservedRemoteSessions == 11)
    _ = runtime.revokeRemote(phone)
    #expect(runtime.reservedRemoteSessions == 4)
    _ = try capacityPair(&runtime,.phone,1.4)
    #expect(runtime.reservedRemoteSessions == 11)
    _ = runtime.disableRemote()
    #expect(runtime.reservedRemoteSessions == 0)
    #expect(runtime.activeSources.contains(.trackpad))
}
@Test func remoteReservationsRejectSecondFullPeerAndRecoverOnExpiry() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true)),allowRemote:true)
    let first = try capacityPair(&runtime,.phone,1)
    #expect(runtime.reservedRemoteSessions == 7)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.phone,1.1) }
    #expect(runtime.remotePeerIDs == [first])
    _ = runtime.expire(now:3.1)
    #expect(runtime.reservedRemoteSessions == 0)
    _ = try capacityPair(&runtime,.phone,3.2)
    #expect(runtime.reservedRemoteSessions == 7)
    _ = runtime.stop()
    #expect(runtime.reservedRemoteSessions == 0)
}
