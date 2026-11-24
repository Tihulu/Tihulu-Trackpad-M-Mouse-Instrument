import Foundation
import Testing
@testable import NoSpeakerCore

// Run only in the disposable package described in REMOTE_R9_PERF_REPORT.md.
private func packet(_ sequence: Int, _ version: Int, _ kind: String,
                    _ fields: [String: Any] = [:]) throws -> Data {
    var object = fields
    object["sequence"] = sequence
    object["version"] = version
    object["kind"] = kind
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
private func patch() -> InstrumentPatch {
    .init(routes: [
        .init(id: "perf-touch", source: .phone, signal: .contact, destination: .init(.note, number: 60)),
        .init(id: "perf-tilt", source: .phone, signal: .tiltPitch, destination: .init(.controlChange, number: 20)),
        .init(id: "perf-accel", source: .phone, signal: .accelerationMagnitude, destination: .init(.controlChange, number: 21)),
        .init(id: "perf-rotation", source: .phone, signal: .rotationMagnitude, destination: .init(.controlChange, number: 22)),
        .init(id: "perf-drum", source: .phone, signal: .drumPad1, destination: .init(.note, channel: 9, number: 36)),
        .init(id: "perf-piano", source: .phone, signal: RemotePiano.signals[0], destination: .init(.note, number: 48)),
        .init(id: "perf-pedal", source: .phone, signal: .pedalSustain, destination: .init(.sustain))
    ])
}
private func pair(_ runtime: inout PhysicalPatchRuntime, _ byte: UInt8) throws -> UUID {
    let key = Data(repeating: byte, count: 32)
    try runtime.issueRemotePairing(secret: key, source: .phone, now: 1)
    return try runtime.admitRemote(secret: key, now: 1)
}

@Test func r9PerfPeerAndRateCaps() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch(), allowRemote: true)
    var peers: [UUID] = []
    for i in 1...4 { peers.append(try pair(&runtime, UInt8(i))) }
    #expect(throws: RemoteTouchError.capacity) { try pair(&runtime, 5) }
    for sequence in 1...90 {
        let result = runtime.receiveRemote(peers[0], bytes: try packet(sequence, 1, "touch", ["x": 0.3, "y": 0.7]), now: 1.1)
        if case .close = result { Issue.record("Unexpected rejection before rate cap: \(sequence)") }
    }
    let rejected = runtime.receiveRemote(peers[0], bytes: try packet(91, 1, "touch", ["x": 0.3, "y": 0.7]), now: 1.1)
    #expect(rejected == .close([.init(.init(.note, number: 60), value: 0)]))
    #expect(runtime.remotePeerIDs.count == 3)
}

@Test func r9PerfRouterCapacityRecovery() throws {
    var router = SensorRouter()
    try router.configure(patch().routes)
    var sessions: [UUID] = []
    for _ in 0..<16 { sessions.append(try router.connect(.phone, now: 1)) }
    #expect(throws: SensorRouterError.sessionLimit) { try router.connect(.phone, now: 1) }
    _ = router.disconnect(sessions.removeLast())
    _ = try router.connect(.phone, now: 1.01)
}

@Test func r9PerfConcurrentPeerCapacityAndRelease() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch(), allowRemote: true)
    let peers = try (1...3).map { try pair(&runtime, UInt8($0)) }
    let angles: [String: Any] = ["alpha": 0, "beta": 10, "gamma": 0]
    let vector: [String: Any] = ["x": 10, "y": 0, "z": 0]
    let frames: [(Int, String, [String: Any])] = [
        (1, "touch", ["x": 0.3, "y": 0.7]),
        (2, "orientationArm", angles), (2, "orientation", angles),
        (3, "accelerationArm", vector), (3, "acceleration", vector),
        (3, "rotationArm", vector), (3, "rotation", vector),
        (4, "drumPads", ["mask": 1]), (5, "pianoKeys", ["mask": 1]),
        (6, "pedalboard", ["mask": 8, "levels": [0,0,0,1,0,0]])
    ]
    var rejectedPeers: [Int] = []
    for (i, peer) in peers.enumerated() {
        for (j, frame) in frames.enumerated() {
            let now = 1.01 + Double(i * frames.count + j) * 0.005
            let result = runtime.receiveRemote(peer, bytes: try packet(j+1, frame.0, frame.1, frame.2), now: now)
            if case .close = result { rejectedPeers.append(i); break }
        }
    }
    // 14 sessions from the first two peers; third exceeds the global 16 cap.
    #expect(rejectedPeers == [2])
    #expect(runtime.remotePeerIDs == Set(peers.prefix(2)))
    let firstRelease = runtime.revokeRemote(peers[0])
    #expect(firstRelease.isEmpty) // same destinations still owned by peer two
    let finalRelease = runtime.revokeRemote(peers[1])
    #expect(finalRelease.contains(.init(.init(.note, number: 60), value: 0)))
    #expect(finalRelease.contains(.init(.init(.note, channel: 9, number: 36), value: 0)))
    #expect(finalRelease.contains(.init(.init(.note, number: 48), value: 0)))
    #expect(finalRelease.contains(.init(.init(.sustain), value: 0)))
    #expect(runtime.remotePeerIDs.isEmpty)
    #expect(runtime.stop().isEmpty)
}
