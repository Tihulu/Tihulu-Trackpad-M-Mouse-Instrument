import Foundation
import Testing
@testable import NoSpeakerCore

private func ms(_ n:Int64)->Int64 {n*1_000_000}
private func packet(_ action:MobileAirSendGate.Action) throws -> RemoteTouchFrame {
    guard case .send(let data)=action else {throw RemoteTouchError.invalidFrame}
    return try RemoteTouchFrame.read(data)
}
@Test func mobileSendGateNeutralACKAndSequence() throws {
    var g=try #require(MobileAirSendGate(lane:.keys(authorized:3),initialSequence:8))
    let initial=try packet(g.begin(now:0))
    #expect(initial.sequence==9 && initial.mask==0)
    #expect(g.offer(.init(keys:1),observedAt:ms(1),now:ms(1)) == .wait)
    #expect(g.acknowledge("accepted",now:ms(20)) == .wait)
    #expect(g.offer(.init(keys:1),observedAt:ms(19),now:ms(21)) == .wait)
    let attack=try packet(g.offer(.init(keys:1),observedAt:ms(22),now:ms(22)))
    #expect(attack.sequence==10 && attack.mask==1)
}
@Test func mobileSendGateReleaseFenceAndGap() throws {
    var g=try #require(MobileAirSendGate(lane:.keys(authorized:3),initialSequence:0))
    _=g.begin(now:0);_=g.acknowledge("accepted",now:ms(20))
    _=g.offer(.init(keys:1),observedAt:ms(21),now:ms(21))
    #expect(g.offer(.init(),observedAt:ms(30),now:ms(30)) == .wait)
    #expect(g.offer(.init(keys:2),observedAt:ms(31),now:ms(31)) == .wait)
    #expect(try packet(g.acknowledge("accepted",now:ms(40))).mask==0)
    #expect(g.acknowledge("accepted",now:ms(60)) == .wait)
    #expect(g.offer(.init(keys:2),observedAt:ms(59),now:ms(61)) == .wait)
    #expect(try packet(g.offer(.init(keys:2),observedAt:ms(62),now:ms(62))).mask==2)
    _=g.acknowledge("accepted",now:ms(80))
    #expect(try packet(g.offer(.init(keys:2),observedAt:ms(220),now:ms(220))).mask==0)
}
@Test func mobileSendGateExpiredPendingAndReleaseDeadline() throws {
    var g=try #require(MobileAirSendGate(lane:.keys(authorized:1),initialSequence:0))
    _=g.begin(now:0);_=g.acknowledge("accepted",now:ms(20))
    _=g.offer(.init(keys:1),observedAt:ms(21),now:ms(21))
    #expect(g.offer(.init(keys:1),observedAt:ms(180),now:ms(180)) == .close("Source expired while active ACK outstanding"))
    var h=try #require(MobileAirSendGate(lane:.keys(authorized:1),initialSequence:0))
    _=h.begin(now:0);_=h.acknowledge("accepted",now:ms(20))
    _=h.offer(.init(keys:1),observedAt:ms(21),now:ms(21))
    _=h.offer(.init(),observedAt:ms(30),now:ms(100))
    #expect(h.poll(now:ms(180)) == .close("Release overdue"))
}
@Test func mobileSendGateHelperZeroHeartbeatAndTimeout() throws {
    var g=try #require(MobileAirSendGate(lane:.helper(index:2,authorized:4),initialSequence:0))
    _=g.begin(now:0);_=g.acknowledge("accepted",now:ms(20))
    #expect(try packet(g.offer(.init(level:0),observedAt:ms(21),now:ms(21))).mask==4)
    _=g.acknowledge("accepted",now:ms(40))
    #expect(try packet(g.poll(now:ms(171))).mask==0)
    _=g.acknowledge("accepted",now:ms(180))
    #expect(try packet(g.poll(now:ms(1171))).kind == .heartbeat)
    #expect(g.poll(now:ms(1391)) == .close("ACK timeout"))
}
@Test func mobileSendGateRejectsInvalidLaneReplayAndClock() throws {
    #expect(MobileAirSendGate(lane:.helper(index:3,authorized:8),initialSequence:0)==nil)
    var g=try #require(MobileAirSendGate(lane:.keys(authorized:1),initialSequence:0))
    _=g.begin(now:0);_=g.acknowledge("accepted",now:ms(20))
    _=g.offer(.init(keys:1),observedAt:ms(21),now:ms(21))
    #expect(g.offer(.init(keys:1),observedAt:ms(21),now:ms(22)) == .close("Stale or replayed observation"))
    var h=try #require(MobileAirSendGate(lane:.keys(authorized:1),initialSequence:0))
    _=h.begin(now:ms(10))
    #expect(h.poll(now:ms(9)) == .close("Invalid monotonic clock"))
}
