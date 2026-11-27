import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Session = NativeHelperRelativeSession
private typealias Clutch = NativeHelperRelativeClutch
private let registration = UUID()
private struct Wire {
    var calls: [String] = []
    var beginOK = true, moveOK = true, clean = true, permitted = true, leaseValid = true
}
private func session(_ token: UUID, source: Clutch.Surface = .magicMouse, cutoff: Int64 = 0) throws -> Session {
    try #require(Session(source: source, monitor: token, registration: registration, afterSequence: 10, afterAcquisitionNS: cutoff, maximumAge: 0.125,
                         lanes: [.x: .init(reference: 8192, upper: 16383)]))
}
private func frame(_ time: Double, x: Double? = nil, count: Int? = nil,
                   source: Clutch.Surface = .magicMouse, nativeRegistration: UUID? = registration,
                   hasAcquisition: Bool = true) -> Clutch.SourceFrame {
    let contacts = x.map { [Clutch.Contact(surface: source,id: 1,x:$0,y:0.5,contactSize:0.5)] } ?? []
    return .init(surface:source,rawDownCount:count ?? contacts.count,sourceConsistent:true,contacts:contacts,receipt:time,
                 nativeRegistration:nativeRegistration, acquisitionNS:hasAcquisition ? Int64(time * 1_000_000_000) : nil)
}
private func receive(_ s: inout Session, _ wire: inout Wire, _ f: Clutch.SourceFrame,
                     _ token: UUID, _ seq: UInt64, now: Double? = nil) -> Session.Result {
    let lease = wire.leaseValid
    let permits = wire.permitted, beginOK = wire.beginOK, moveOK = wire.moveOK, clean = wire.clean
    var calls: [String] = []
    let result = s.receive(f, monitor:token, sequence:seq, now:now ?? f.receipt, permits:{ permits }, activeLeaseValid:{ lease }, begin:{
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
    #expect(s.receive(frame(1.03125,x:0.5),monitor:token,sequence:12,now:1.03125,permits:{allowed},activeLeaseValid:{true},begin:{allowed=false;return true},move:{_ in true},retire:{retired.append($0);return true}) == .retired)
    #expect(retired == [false])
    _ = receive(&s,&w,frame(1.0625),token,13)
    _ = receive(&s,&w,frame(1.09375,x:0.5),token,14)
    allowed = true
    #expect(s.receive(frame(1.125,x:0.75),monitor:token,sequence:15,now:1.125,permits:{allowed},activeLeaseValid:{true},begin:{true},move:{_ in allowed=false;return true},retire:{retired.append($0);return true}) == .retired)
    #expect(retired == [false,false])
}

@Test func relativeSessionNativeRegistrationReplacementPermanentlyCloses() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    _ = receive(&s,&w,frame(1),token,11)
    _ = receive(&s,&w,frame(1.03125,x:0.5),token,12)
    #expect(receive(&s,&w,frame(1.0625,nativeRegistration:UUID()),token,13) == .retired)
    #expect(w.calls.last == "retire:false")
    #expect(receive(&s,&w,frame(1.09375),token,14) == .ignored)
    #expect(receive(&s,&w,frame(1.125,x:0.5),token,15) == .ignored)
}
@Test func relativeSessionMissingOriginalAcquisitionCannotRearm() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    #expect(receive(&s,&w,frame(1,hasAcquisition:false),token,11) == .retired)
    #expect(receive(&s,&w,frame(1.03125,x:0.5),token,12) == .waiting)
    #expect(receive(&s,&w,frame(1.0625),token,13) == .waiting)
    #expect(receive(&s,&w,frame(1.09375,x:0.5),token,14) == .anchored)
}

@Test func relativeSessionRejectsAcquisitionBeforeOrAtArm() throws {
    for time in [0.96875, 1.0] {
        let token = UUID(); var s = try session(token, cutoff: 1_000_000_000), w = Wire()
        #expect(receive(&s,&w,frame(time),token,11,now:1.0) == .retired)
        #expect(w.calls == ["retire:false"])
        #expect(receive(&s,&w,frame(1.03125,x:0.5),token,12) == .waiting)
        #expect(receive(&s,&w,frame(1.0625),token,13) == .waiting)
        #expect(receive(&s,&w,frame(1.09375,x:0.5),token,14) == .anchored)
    }
    #expect(Session(source:.magicMouse,monitor:UUID(),registration:registration,afterSequence:0,
                    afterAcquisitionNS:-1,maximumAge:0.125,lanes:[.x:.init(reference:8192,upper:16383)]) == nil)
}

@Test func relativeSessionDoubleCollisionDoesNotAuthorizeNeutral() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    let ns: Int64 = 100_000_000_000_000_000
    func exact(_ n: Int64, down: Bool = false) -> Clutch.SourceFrame {
        let contacts: [Clutch.Contact] = down ? [.init(surface:.magicMouse,id:1,x:0.5,y:0.5,contactSize:0.5)] : []
        return .init(surface:.magicMouse,rawDownCount:contacts.count,sourceConsistent:true,contacts:contacts,
                     receipt:Double(n)/1_000_000_000,nativeRegistration:registration,acquisitionNS:n)
    }
    let anchored = ns + 31_250_000
    #expect(exact(anchored).receipt == exact(anchored+1).receipt)
    #expect(receive(&s,&w,exact(ns),token,11) == .waiting)
    #expect(receive(&s,&w,exact(anchored,down:true),token,12) == .anchored)
    #expect(receive(&s,&w,exact(anchored+1),token,13) == .retired)
    #expect(w.calls.last == "retire:false")
    #expect(receive(&s,&w,exact(anchored+31_250_000,down:true),token,14) == .waiting)
    #expect(receive(&s,&w,exact(anchored+62_500_000),token,15) == .waiting)
    #expect(receive(&s,&w,exact(anchored+93_750_000,down:true),token,16) == .anchored)
}

@Test func relativeSessionStationaryLeaseLossRequiresCleanNeutral() throws {
    let token = UUID(); var s = try session(token), w = Wire()
    #expect(receive(&s,&w,frame(1),token,11) == .waiting)
    #expect(receive(&s,&w,frame(1.03125,x:0.5),token,12) == .anchored)
    w.leaseValid = false
    #expect(receive(&s,&w,frame(1.0625,x:0.5),token,13) == .retired)
    #expect(w.calls.last == "retire:false")
    w.leaseValid = true
    #expect(receive(&s,&w,frame(1.09375,x:0.6),token,14) == .waiting)
    w.clean = false
    #expect(receive(&s,&w,frame(1.125),token,15) == .retired)
    w.clean = true
    #expect(receive(&s,&w,frame(1.15625,x:0.6),token,16) == .waiting)
    #expect(receive(&s,&w,frame(1.1875),token,17) == .waiting)
    #expect(receive(&s,&w,frame(1.21875,x:0.5),token,18) == .anchored)
    #expect(w.calls.filter{$0 == "begin"}.count == 2)
}

@Test func relativeSessionLeaseLossInsideCallbacksRetires() throws {
    for lossDuringBegin in [true,false] {
        let token = UUID(); var s = try session(token), w = Wire()
        _ = receive(&s,&w,frame(1),token,11)
        var lease = true, retired: [Bool] = []
        let result = s.receive(frame(1.03125,x:0.5),monitor:token,sequence:12,now:1.03125,
            permits:{true},activeLeaseValid:{lease},begin:{if lossDuringBegin {lease=false};return true},
            move:{_ in true},retire:{retired.append($0);return true})
        if lossDuringBegin { #expect(result == .retired) }
        else {
            #expect(result == .anchored)
            #expect(s.receive(frame(1.0625,x:0.75),monitor:token,sequence:13,now:1.0625,
                permits:{true},activeLeaseValid:{lease},begin:{true},move:{_ in lease=false;return true},
                retire:{retired.append($0);return true}) == .retired)
        }
        #expect(retired == [false])
    }
}
