import Foundation
import Testing
@testable import NoSpeakerCore

private func remoteBytes(_ seq: Int, kind: String = "touch", extra: String = "") -> Data {
    let axes = kind == "touch" ? ",\"x\":0.8,\"y\":0.2" : ""
    return Data(("{\"version\":1,\"sequence\":\(seq),\"kind\":\"\(kind)\""+axes+extra+"}").utf8)
}
private let remoteNote = SensorDestination(.note, number: 60)
private let remotePatch = InstrumentPatch(routes: [
    .init(id: "phone", source: .phone, signal: .contact, destination: remoteNote),
    .init(id: "local", source: .trackpad, signal: .contact, destination: remoteNote)
])
private func pair(_ runtime: inout PhysicalPatchRuntime, at now: Double, byte: UInt8 = 7) throws -> UUID {
    let token = Data(repeating: byte, count: 32)
    try runtime.issueRemotePairing(secret: token, source: .phone, now: now)
    return try runtime.admitRemote(secret: token, now: now)
}

@Test func remoteExplicitOptInPairingScopeAndReplay() throws {
    #expect(!PhysicalPatchRuntime.supports(remotePatch))
    #expect(PhysicalPatchRuntime.supports(remotePatch, allowRemote: true))
    var runtime = PhysicalPatchRuntime()
    let token = Data(repeating: 7, count: 32)
    #expect(throws: RemoteTouchError.unavailable) {
        try runtime.issueRemotePairing(secret: token, source: .phone, now: 1)
    }
    try runtime.configure(remotePatch, allowRemote: true)
    #expect(throws: RemoteTouchError.unavailable) {
        try runtime.issueRemotePairing(secret: token, source: .tablet, now: 1)
    }
    try runtime.issueRemotePairing(secret: token, source: .phone, now: 1)
    #expect(throws: RemoteTouchError.invalidPairing) {
        try runtime.admitRemote(secret: Data(repeating: 8, count: 32), now: 1)
    }
    let id = try runtime.admitRemote(secret: token, now: 1)
    #expect(throws: RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret: token, now: 1) }
    #expect(runtime.receiveRemote(id, bytes: remoteBytes(1), now: 1.1) == .accepted([.init(remoteNote, value: 100)]))
    #expect(runtime.receiveRemote(id, bytes: remoteBytes(1), now: 1.2) == .close([.init(remoteNote, value: 0)]))
    #expect(runtime.remotePeerIDs.isEmpty)
    try runtime.issueRemotePairing(secret: token, source: .phone, now: 2)
    #expect(throws: RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret: token, now: 62) }
}

@Test func remotePeerReleasePreservesOtherPeerAndLocalOwners() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(remotePatch, allowRemote: true)
    let a = try pair(&runtime, at: 1)
    let b = try pair(&runtime, at: 1, byte: 8)
    #expect(runtime.receiveRemote(a, bytes: remoteBytes(1), now: 1.1) == .accepted([.init(remoteNote, value: 100)]))
    #expect(runtime.receiveRemote(b, bytes: remoteBytes(1), now: 1.1) == .accepted([]))
    #expect(runtime.receive(source: .trackpad, x: 0.5, y: 0.5, size: 0.5, hostTime: 1.1, now: 1.1).isEmpty)
    #expect(runtime.revokeRemote(a).isEmpty)
    #expect(runtime.receiveRemote(b, bytes: remoteBytes(2, kind: "release"), now: 1.2) == .accepted([]))
    #expect(runtime.receive(source: .trackpad, x: nil, y: nil, size: nil, hostTime: 1.2, now: 1.2) == [.init(remoteNote, value: 0)])
    #expect(runtime.receiveRemote(b, bytes: remoteBytes(3), now: 1.3) == .accepted([.init(remoteNote, value: 100)]))
    #expect(runtime.expire(now: 1.7) == [.init(remoteNote, value: 0)])
    #expect(runtime.remotePeerIDs.isEmpty)
}

@Test func remoteWireRejectsUnsupportedFieldsAndBounds() throws {
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(remoteBytes(1, extra: ",\"channel\":1")) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(Data(repeating: 65, count: 257)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(Data("{\"version\":1,\"sequence\":1,\"kind\":\"touch\",\"x\":2,\"y\":0}".utf8)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(remoteBytes(0)) }
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(remotePatch, allowRemote: true)
    let id = try pair(&runtime, at: 1)
    _ = runtime.receiveRemote(id, bytes: remoteBytes(1), now: 1.1)
    #expect(runtime.receiveRemote(id, bytes: remoteBytes(2, kind: "heartbeat"), now: 1.2) == .close([.init(remoteNote, value: 0)]))
}

@Test func remoteCapacityRateAndStopFence() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(remotePatch, allowRemote: true)
    var ids: [UUID] = []
    for i in 1...4 { ids.append(try pair(&runtime, at: 1, byte: UInt8(i))) }
    #expect(throws: RemoteTouchError.capacity) { try pair(&runtime, at: 1, byte: 5) }
    for i in 1...90 {
        let expected: RemoteTouchResult = .accepted(i == 1 ? [.init(remoteNote, value: 100)] : [])
        #expect(runtime.receiveRemote(ids[0], bytes: remoteBytes(i), now: 1.1) == expected)
    }
    #expect(runtime.receiveRemote(ids[0], bytes: remoteBytes(91), now: 1.1) == .close([.init(remoteNote, value: 0)]))
    #expect(runtime.receiveRemote(ids[1], bytes: remoteBytes(1), now: 1.2) == .accepted([.init(remoteNote, value: 100)]))
    #expect(runtime.stop() == [.init(remoteNote, value: 0)])
    #expect(runtime.receiveRemote(ids[1], bytes: remoteBytes(2), now: 1.3) == .close([]))
    #expect(throws: RemoteTouchError.unavailable) { try runtime.admitRemote(secret: Data(repeating: 5, count: 32), now: 1.3) }
}
