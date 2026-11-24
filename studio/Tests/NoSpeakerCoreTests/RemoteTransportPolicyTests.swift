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
    #expect(gate.receiveInvitation(secret, binary: true, now: 1.1))
    #expect(gate.phase == .awaitingHost)
    #expect(gate.admit(now: 1.2))
    #expect(gate.receiveFrame(frame, text: true, now: 1.3))
    #expect(!gate.receiveFrame(frame, text: false, now: 1.4))
    #expect(gate.phase == .closed)
    var before = RemoteConnectionGate(now: 1)
    #expect(!before.receiveFrame(frame, text: true, now: 1.1))
    var late = RemoteConnectionGate(now: 1)
    #expect(!late.receiveInvitation(secret, binary: true, now: 6))
    var unapproved = RemoteConnectionGate(now: 1)
    #expect(unapproved.receiveInvitation(secret, binary: true, now: 2))
    #expect(!unapproved.admit(now: 6))
}

@Test func remoteConnectionGateRejectsIdleAndInvalidData() {
    var gate = RemoteConnectionGate(now: 1)
    #expect(gate.receiveInvitation(Data(repeating: 1, count: 32), binary: true, now: 1))
    #expect(gate.admit(now: 1))
    #expect(gate.expired(now: 3))
    #expect(!gate.receiveFrame(Data(repeating: 0, count: 257), text: true, now: 2))
    #expect(gate.phase == .closed)
}
