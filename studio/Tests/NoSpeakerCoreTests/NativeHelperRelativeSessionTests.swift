import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Session = NativeHelperRelativeSession
private typealias Clutch = NativeHelperRelativeClutch
private struct Wire {
    var calls: [String] = []
    var beginOK = true, moveOK = true, clean = true, permitted = true
}
private func session(_ token: UUID, source: Clutch.Surface = .magicMouse) throws -> Session {
    try #require(Session(source: source, monitor: token, afterSequence: 10, maximumAge: 0.125,
                         lanes: [.x: .init(reference: 8192, upper: 16383)]))
}
private func frame(_ time: Double, x: Double? = nil, count: Int? = nil,
                   source: Clutch.Surface = .magicMouse) -> Clutch.SourceFrame {
    let contacts = x.map { [Clutch.Contact(surface: source,id: 1,x:$0,y:0.5,contactSize:0.5)] } ?? []
    return .init(surface:source,rawDownCount:count ?? contacts.count,sourceConsistent:true,contacts:contacts,receipt:time)
}
private func receive(_ s: inout Session, _ wire: inout Wire, _ f: Clutch.SourceFrame,
                     _ token: UUID, _ seq: UInt64, now: Double? = nil) -> Session.Result {
    let permits = wire.permitted, beginOK = wire.beginOK, moveOK = wire.moveOK, clean = wire.clean
    var calls: [String] = []
    let result = s.receive(f, monitor:token, sequence:seq, now:now ?? f.receipt, permits:{ permits }, begin:{
        calls.append("begin"); return beginOK
    }, move:{ values in calls.append("move:\(values[.x] ?? -1)"); return moveOK }, retire:{ neutral in
        calls.append("retire:\(neutral)"); return clean
    })
    wire.calls += calls
    return result
}
@Test func relativeSessionRequiresSelectedFreshNeutralAndNeverSendsAnchor() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    #expect(receive(&s,&w,frame(1),UUID(),11) == .ignored)
    #expect(receive(&s,&w,frame(1,source:.trackpad),token,11) == .ignored)
    #expect(receive(&s,&w,frame(1),token,10) == .ignored)
    #expect(receive(&s,&w,frame(1,x:0.5),token,11) == .waiting)
    #expect(w.calls.isEmpty)
    #expect(receive(&s,&w,frame(1.03125),token,12) == .waiting)
    #expect(receive(&s,&w,frame(1.0625,x:0.5),token,13) == .anchored)
    #expect(w.calls == ["retire:true","begin"])
    #expect(receive(&s,&w,frame(1.09375,x:0.75),token,14) == .accepted)
    #expect(w.calls.last == "move:12288")
    #expect(receive(&s,&w,frame(1.125),token,15) == .waiting)
    #expect(w.calls.last == "retire:true")
}
@Test func relativeSessionFailedBeginAndCleanupRequireAnotherRealLift() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    _ = receive(&s,&w,frame(1),token,11)
    w.beginOK = false
    #expect(receive(&s,&w,frame(1.03125,x:0.5),token,12) == .retired)
    w.beginOK = true
    #expect(receive(&s,&w,frame(1.0625,x:0.6),token,13) == .waiting)
    w.clean = false
    #expect(receive(&s,&w,frame(1.09375),token,14) == .retired)
    w.clean = true
    #expect(receive(&s,&w,frame(1.125,x:0.7),token,15) == .waiting)
    #expect(receive(&s,&w,frame(1.15625),token,16) == .waiting)
    #expect(receive(&s,&w,frame(1.1875,x:0.7),token,17) == .anchored)
    #expect(w.calls.filter{$0 == "begin"}.count == 2)
}
@Test func relativeSessionExpiryAndDelayedWatchdogCannotReanchorHeldContact() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    _ = receive(&s,&w,frame(1),token,11)
    _ = receive(&s,&w,frame(1.03125,x:0.5),token,12)
    #expect(receive(&s,&w,frame(1.15625,x:0.6),token,13) == .retired)
    #expect(w.calls.last == "retire:false")
    #expect(receive(&s,&w,frame(1.1875,x:0.6),token,14) == .waiting)
    _ = receive(&s,&w,frame(1.21875),token,15)
    _ = receive(&s,&w,frame(1.25,x:0.5),token,16)
    #expect(s.expire(now:1.34375,retire:{ _ in false }) == .ignored)
    #expect(s.expire(now:1.375,retire:{ neutral in !neutral }) == .retired)
    #expect(s.expire(now:2,retire:{ _ in false }) == .ignored)
    #expect(receive(&s,&w,frame(2,x:0.5),token,17) == .waiting)
}
@Test func relativeSessionRejectedReceiptCannotRearmAndCloseIsPermanent() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    _ = receive(&s,&w,frame(1),token,11)
    _ = receive(&s,&w,frame(1.03125,x:0.5),token,12)
    w.permitted = false
    #expect(receive(&s,&w,frame(1.0625),token,13) == .retired)
    w.permitted = true
    #expect(receive(&s,&w,frame(1.0625),token,14) == .retired)
    #expect(receive(&s,&w,frame(1.09375,count:1),token,15) == .waiting)
    #expect(receive(&s,&w,frame(1.125,x:0.5),token,16) == .waiting)
    #expect(s.close(retire:{ !$0 }) == .retired)
    #expect(receive(&s,&w,frame(2),token,17) == .ignored)
    #expect(receive(&s,&w,frame(2.03125,x:0.5),token,18) == .ignored)
}
@Test func relativeSessionAdmissionLossAfterBeginAndMoveRetires() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    _ = receive(&s,&w,frame(1),token,11)
    var allowed = true, retired: [Bool] = []
    #expect(s.receive(frame(1.03125,x:0.5),monitor:token,sequence:12,now:1.03125,permits:{allowed},begin:{allowed=false;return true},move:{_ in true},retire:{retired.append($0);return true}) == .retired)
    #expect(retired == [false])
    _ = receive(&s,&w,frame(1.0625),token,13)
    _ = receive(&s,&w,frame(1.09375,x:0.5),token,14)
    allowed = true
    #expect(s.receive(frame(1.125,x:0.75),monitor:token,sequence:15,now:1.125,permits:{allowed},begin:{true},move:{_ in allowed=false;return true},retire:{retired.append($0);return true}) == .retired)
    #expect(retired == [false,false])
}
