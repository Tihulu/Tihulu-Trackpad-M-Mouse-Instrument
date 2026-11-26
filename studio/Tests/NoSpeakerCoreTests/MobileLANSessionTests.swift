import Foundation
import Testing
@testable import NoSpeakerCore
private let invitation=String(repeating:"ab",count:32)
private func ns(_ n:Int64)->Int64{n*1_000_000}
private func packet(_ a:MobileLANSession.Action)throws->RemoteTouchFrame {
    guard case .text(let data)=a else{throw RemoteTouchError.invalidFrame}
    return try RemoteTouchFrame.read(data)
}
private func host(_ piano:Int=1,_ pedals:Int=0)throws->String {
    String(decoding:try RemoteCapabilities(touch:false,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:0,piano:piano,pedals:pedals).encoded(),as:UTF8.self)
}
@Test func mobileLANSessionFullLogicalHandshakeAndFreshAttack() throws {
    var s=MobileLANSession(selection:.keys)
    #expect(s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0) == .binary(Data(repeating:0xab,count:32)))
    let cap=try packet(s.receive(text:"admitted",now:ns(10)))
    #expect(cap.kind == .capabilities && cap.sequence==1)
    #expect(s.receive(text:try host(),now:ns(11)) == .wait)
    let neutral=try packet(s.poll(now:ns(23)))
    #expect(neutral.mask==0 && neutral.sequence==2)
    #expect(s.offer(.init(keys:1),observedAt:ns(24),now:ns(24)) == .wait)
    #expect(s.receive(text:"accepted",now:ns(40)) == .wait)
    #expect(s.phase == .ready)
    #expect(s.offer(.init(keys:1),observedAt:ns(39),now:ns(41)) == .wait)
    let attack=try packet(s.offer(.init(keys:1),observedAt:ns(42),now:ns(42)))
    #expect(attack.sequence==3 && attack.mask==1)
}
@Test func mobileLANSessionNoTrustOrWrongSubprotocolNeverSendsInvitation(){
    for (trust,proto) in [(false,"tihulu-touch-v1"),(true,"other")] {
        var s=MobileLANSession(selection:.keys)
        #expect(s.begin(trustedTLS:trust,subprotocol:proto,invitation:invitation,now:0) == .close("Untrusted or invalid connection"))
        #expect(s.phase == .closed)
    }
}
@Test func mobileLANSessionRejectsTimeoutAndUnassignedFamily() throws {
    var s=MobileLANSession(selection:.helper(0))
    _=s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    _=s.receive(text:"admitted",now:ns(1))
    #expect(s.receive(text:try host(0,4),now:ns(2)) == .close("Unassigned lane"))
    var t=MobileLANSession(selection:.keys)
    _=t.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    #expect(t.receive(text:"admitted",now:ns(3000)) == .close("Negotiation timeout"))
}
@Test func mobileLANSessionNeutralTimeoutAndAbortAreTerminal() throws {
    var s=MobileLANSession(selection:.keys)
    _=s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    _=s.receive(text:"admitted",now:ns(1))
    _=s.receive(text:try host(),now:ns(14))
    #expect(s.receive(text:"accepted",now:ns(234)) == .close("ACK timeout"))
    #expect(s.phase == .closed)
    #expect(s.poll(now:ns(235)) == .close("Already closed"))
}
