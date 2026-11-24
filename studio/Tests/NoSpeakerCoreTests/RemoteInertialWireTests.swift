import Foundation
import Testing
@testable import NoSpeakerCore

private let accelCC = SensorDestination(.controlChange, number: 74)
private let rotationCC = SensorDestination(.controlChange, number: 1)
private let inertialPatch = InstrumentPatch(routes: [
    .init(id: "a", source: .phone, signal: .accelerationMagnitude, destination: accelCC),
    .init(id: "r", source: .phone, signal: .rotationMagnitude, destination: rotationCC)
])
private func vector(_ sequence: Int, _ kind: String, x: Double = 0, version: Int = 3) -> Data {
    let axes = kind.hasSuffix("Release") || kind == "heartbeat" ? "" : ",\"x\":\(x),\"y\":0,\"z\":0"
    return Data(("{\"version\":\(version),\"sequence\":\(sequence),\"kind\":\"\(kind)\"" + axes + "}").utf8)
}
private func inertialPair(_ runtime: inout PhysicalPatchRuntime) throws -> UUID {
    let token = Data(repeating: 12, count: 32)
    try runtime.configure(inertialPatch, allowRemote: true)
    try runtime.issueRemotePairing(secret: token, source: .phone, now: 1)
    return try runtime.admitRemote(secret: token, now: 1)
}

@Test func remoteInertialStrictBoundsAndVersion() throws {
    let a = try RemoteTouchFrame.read(vector(1, "acceleration", x: 10))
    let r = try RemoteTouchFrame.read(vector(2, "rotation", x: 180))
    #expect(a.inertialValue == 0.5)
    #expect(r.inertialValue == 0.5)
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(vector(1, "acceleration", x: 101)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(vector(1, "rotation", x: 2001)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(vector(1, "rotation", version: 2)) }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":3,\"sequence\":1,\"kind\":\"acceleration\",\"x\":1,\"y\":0}".utf8))
    }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":3,\"sequence\":1,\"kind\":\"rotationRelease\",\"x\":0}".utf8))
    }
}

@Test func remoteInertialIndependentArmAndRelease() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try inertialPair(&runtime)
    let a = runtime.receiveRemote(id, bytes: vector(1,"accelerationArm"), now: 1.1)
    let b = runtime.receiveRemote(id, bytes: vector(2,"rotationArm"), now: 1.11)
    #expect(a == .accepted([]))
    #expect(b == .accepted([]))
    let aa = runtime.receiveRemote(id, bytes: vector(3,"acceleration",x: 10), now: 1.2)
    let bb = runtime.receiveRemote(id, bytes: vector(4,"rotation",x: 180), now: 1.21)
    #expect(aa == .accepted([.init(accelCC,value: 64)]))
    #expect(bb == .accepted([.init(rotationCC,value: 64)]))
    let release = runtime.receiveRemote(id, bytes: vector(5,"accelerationRelease"), now: 1.22)
    #expect(release == .accepted([.init(accelCC,value: 0)]))
    let fresh = runtime.receiveRemote(id, bytes: vector(6,"rotation",x: 360), now: 1.23)
    #expect(fresh == .accepted([.init(rotationCC,value: 127)]))
    let stop = runtime.receiveRemote(id, bytes: vector(7,"rotationRelease"), now: 1.24)
    #expect(stop == .accepted([.init(rotationCC,value: 0)]))
}

@Test func remoteInertialStaleStreamRevokesBothDirections() throws {
    for staleAcceleration in [true,false] {
        var runtime = PhysicalPatchRuntime()
        let id = try inertialPair(&runtime)
        _ = runtime.receiveRemote(id, bytes: vector(1,"accelerationArm"), now: 1.1)
        _ = runtime.receiveRemote(id, bytes: vector(2,"rotationArm"), now: 1.11)
        _ = runtime.receiveRemote(id, bytes: vector(3,"acceleration",x: 20), now: 1.2)
        _ = runtime.receiveRemote(id, bytes: vector(4,"rotation",x: 360), now: 1.21)
        let kind = staleAcceleration ? "rotation" : "acceleration"
        let fresh = runtime.receiveRemote(id, bytes: vector(5,kind,x: staleAcceleration ? 360 : 20), now: 1.4)
        #expect(fresh == .accepted([]))
        let expired = runtime.expire(now: 1.6)
        #expect(expired.contains(.init(accelCC,value: 0)))
        #expect(expired.contains(.init(rotationCC,value: 0)))
        #expect(runtime.remotePeerIDs.isEmpty)
    }
}

@Test func remoteInertialRejectsUnarmedReplayAndGateRoutes() throws {
    let invalid = InstrumentPatch(routes: [.init(id:"bad",source:.phone,signal:.accelerationMagnitude,destination:.init(.note,number:60))])
    #expect(!PhysicalPatchRuntime.supports(invalid,allowRemote:true))
    var runtime = PhysicalPatchRuntime()
    let id = try inertialPair(&runtime)
    let unarmed = runtime.receiveRemote(id, bytes: vector(1,"rotation",x: 180), now: 1.1)
    #expect(unarmed == .close([]))
    let token = Data(repeating: 13,count: 32)
    try runtime.issueRemotePairing(secret:token,source:.phone,now:2)
    let peer = try runtime.admitRemote(secret:token,now:2)
    _ = runtime.receiveRemote(peer,bytes:vector(1,"accelerationArm"),now:2.1)
    _ = runtime.receiveRemote(peer,bytes:vector(2,"acceleration",x:20),now:2.2)
    let replay = runtime.receiveRemote(peer,bytes:vector(2,"acceleration",x:20),now:2.3)
    #expect(replay == .close([.init(accelCC,value:0)]))
}
