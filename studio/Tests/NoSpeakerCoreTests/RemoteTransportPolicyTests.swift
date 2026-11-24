import Foundation
import Testing
@testable import NoSpeakerCore

@Test func remoteHandshakeExactOriginAndHost() throws {
    let policy = try #require(RemoteHandshakePolicy(authority: "127.0.0.1:9443", origin: "https://localhost:8443"))
    let protocols = [RemoteHandshakePolicy.subprotocol]
    let headers = [(name:"Host",value:"127.0.0.1:9443"),(name:"Origin",value:"https://localhost:8443")]
    #expect(policy.permits(protocols: protocols, headers: headers))
    #expect(!policy.permits(protocols: protocols, headers: headers + [headers[1]]))
    #expect(!policy.permits(protocols: protocols, headers: [headers[0], ("Origin","null")]))
    #expect(!policy.permits(protocols: protocols, headers: [headers[0], ("Origin","https://localhost:8443.evil.test")]))
    #expect(!policy.permits(protocols: protocols, headers: [("Host","example.test"),headers[1]]))
    #expect(!policy.permits(protocols: [], headers: headers))
    #expect(RemoteHandshakePolicy(authority: "127.0.0.1:9443", origin: "http://localhost:8443") == nil)
}

@Test func remoteConnectionGateRequiresAdmissionAndCorrectFrameType() {
    let secret = Data(repeating: 1, count: 32)
    let frame = Data("{\"version\":1,\"sequence\":1,\"kind\":\"heartbeat\"}".utf8)
    var gate = RemoteConnectionGate(now: 1)
    let result1 = gate.receiveInvitation(secret, binary: true, now: 1.1)
    #expect(result1)
    #expect(gate.phase == .awaitingHost)
    let result2 = gate.admit(now: 1.2)
    #expect(result2)
    let result3 = gate.receiveFrame(frame, text: true, now: 1.3)
    #expect(result3)
    let result4 = gate.receiveFrame(frame, text: false, now: 1.4)
    #expect(!result4)
    #expect(gate.phase == .closed)
    var before = RemoteConnectionGate(now: 1)
    let result5 = before.receiveFrame(frame, text: true, now: 1.1)
    #expect(!result5)
    var late = RemoteConnectionGate(now: 1)
    let result6 = late.receiveInvitation(secret, binary: true, now: 6)
    #expect(!result6)
    var unapproved = RemoteConnectionGate(now: 1)
    let result7 = unapproved.receiveInvitation(secret, binary: true, now: 2)
    #expect(result7)
    let result8 = unapproved.admit(now: 6)
    #expect(!result8)
}

@Test func remoteConnectionGateRejectsIdleAndInvalidData() {
    var gate = RemoteConnectionGate(now: 1)
    let result9 = gate.receiveInvitation(Data(repeating: 1, count: 32), binary: true, now: 1)
    #expect(result9)
    let result10 = gate.admit(now: 1)
    #expect(result10)
    #expect(gate.expired(now: 3))
    let result11 = gate.receiveFrame(Data(repeating: 0, count: 257), text: true, now: 2)
    #expect(!result11)
    #expect(gate.phase == .closed)
}
