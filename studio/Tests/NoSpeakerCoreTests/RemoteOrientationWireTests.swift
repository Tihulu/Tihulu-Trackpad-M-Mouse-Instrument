import Foundation
import Testing
@testable import NoSpeakerCore

private func tiltBytes(_ seq: Int, _ kind: String, beta: Double = 0, version: Int = 2) -> Data {
    let axes = kind == "orientation" || kind == "orientationArm" ? ",\"alpha\":0,\"beta\":\(beta),\"gamma\":0" : ""
    return Data(("{\"version\":\(version),\"sequence\":\(seq),\"kind\":\"\(kind)\"" + axes + "}").utf8)
}
private let bend = SensorDestination(.pitchBend)
private let patch = InstrumentPatch(routes: [
    .init(id: "tilt", source: .phone, signal: .tiltPitch, destination: bend),
    .init(id: "touch", source: .phone, signal: .contact, destination: .init(.note, number: 60))
])
private func pairTilt(_ runtime: inout PhysicalPatchRuntime, now: Double = 1) throws -> UUID {
    let key = Data(repeating: 42, count: 32)
    try runtime.issueRemotePairing(secret: key, source: .phone, now: now)
    return try runtime.admitRemote(secret: key, now: now)
}

@Test func remoteOrientationWireVersionAndSchema() throws {
    let frame = try RemoteTouchFrame.read(tiltBytes(1, "orientationArm"))
    #expect(frame.angles?.beta == 0)
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(tiltBytes(1, "orientation", version: 1)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(tiltBytes(1, "orientation", beta: 90)) }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":2,\"sequence\":1,\"kind\":\"orientation\",\"alpha\":0,\"beta\":0,\"gamma\":0,\"midi\":9}".utf8))
    }
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data("{\"version\":2,\"sequence\":1,\"kind\":\"orientation\",\"alpha\":0,\"beta\":0}".utf8))
    }
}

@Test func remoteOrientationArmSampleRelease() throws {
    var runtime = PhysicalPatchRuntime()
    #expect(!PhysicalPatchRuntime.supports(patch))
    #expect(PhysicalPatchRuntime.supports(patch, allowRemote: true))
    try runtime.configure(patch, allowRemote: true)
    let id = try pairTilt(&runtime)
    let arm = runtime.receiveRemote(id, bytes: tiltBytes(1, "orientationArm", beta: 10), now: 1.1)
    #expect(arm == .accepted([]))
    let sample = runtime.receiveRemote(id, bytes: tiltBytes(2, "orientation", beta: 55), now: 1.2)
    #expect(sample == .accepted([.init(bend, value: 16383)]))
    let release = runtime.receiveRemote(id, bytes: tiltBytes(3, "motionRelease"), now: 1.3)
    #expect(release == .accepted([.init(bend, value: 8192)]))
    #expect(runtime.remotePeerIDs.contains(id))
    let unarmed = runtime.receiveRemote(id, bytes: tiltBytes(4, "orientation"), now: 1.4)
    #expect(unarmed == .close([]))
}

@Test func remoteOrientationWatchdogAndHeartbeatCannotMaskStale() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch, allowRemote: true)
    let id = try pairTilt(&runtime)
    _ = runtime.receiveRemote(id, bytes: tiltBytes(1, "orientationArm"), now: 1.1)
    _ = runtime.receiveRemote(id, bytes: tiltBytes(2, "orientation", beta: 45), now: 1.2)
    let stale = runtime.expire(now: 1.6)
    #expect(stale == [.init(bend, value: 8192)])
    #expect(runtime.remotePeerIDs.isEmpty)
    let other = try pairTilt(&runtime, now: 2)
    _ = runtime.receiveRemote(other, bytes: tiltBytes(1, "orientationArm"), now: 2.1)
    _ = runtime.receiveRemote(other, bytes: tiltBytes(2, "orientation", beta: 45), now: 2.2)
    let heartbeat = runtime.receiveRemote(other, bytes: tiltBytes(3, "heartbeat", version: 1), now: 2.3)
    #expect(heartbeat == .close([.init(bend, value: 8192)]))
}

@Test func remoteOrientationCannotDriveNotesOrMixActiveTouch() throws {
    let forbidden = InstrumentPatch(routes: [.init(id: "gate", source: .phone, signal: .tiltPitch,
                                                  destination: .init(.note, number: 60))])
    #expect(!PhysicalPatchRuntime.supports(forbidden, allowRemote: true))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch, allowRemote: true)
    let id = try pairTilt(&runtime)
    _ = runtime.receiveRemote(id, bytes: tiltBytes(1, "orientationArm"), now: 1.1)
    _ = runtime.receiveRemote(id, bytes: tiltBytes(2, "orientation", beta: 45), now: 1.2)
    let touch = Data("{\"version\":1,\"sequence\":3,\"kind\":\"touch\",\"x\":0.5,\"y\":0.5}".utf8)
    let mixed = runtime.receiveRemote(id, bytes: touch, now: 1.3)
    #expect(mixed == .close([.init(bend, value: 8192)]))
}
