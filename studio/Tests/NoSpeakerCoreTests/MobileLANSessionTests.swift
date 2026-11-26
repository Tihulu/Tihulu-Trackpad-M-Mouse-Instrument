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

@Test func mobileLANSessionLateActiveACKCannotEraseSourceExpiry() throws {
    var s=MobileLANSession(selection:.keys)
    _=s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    _=s.receive(text:"admitted",now:ns(1))
    _=s.receive(text:try host(),now:ns(14))
    _=s.receive(text:"accepted",now:ns(30))
    _=s.offer(.init(keys:1),observedAt:ns(31),now:ns(31))
    #expect(s.receive(text:"accepted",now:ns(181)) == .close("Source expired while active ACK outstanding"))
}
@Test func mobileLANSessionInteroperatesWithActualGroupBridgeAndScopedCleanup() throws {
    let phone=PerformanceInstrumentGroup(name:"Native phone",patch:.init(routes:[.init(id:"note",source:.phone,signal:.pianoKey0,destination:.init(.note,number:60),velocity:93)]))
    let tablet=PerformanceInstrumentGroup(name:"Other player",patch:.init(routes:[.init(id:"other",source:.tablet,signal:.pianoKey0,destination:.init(.note,number:64))]))
    var hostSession=try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let peer=UUID(),other=UUID(),secret=Data(repeating:0xab,count:32),otherSecret=Data(repeating:2,count:32)
    var sent:[PerformanceGroupCommand]=[]
    let sink:(PerformanceGroupCommand)->Bool={sent.append($0);return true}
    _=bridge.process([.ready],now:1,session:&hostSession,send:sink)
    try bridge.issue(secret:otherSecret,source:.tablet,now:1,session:hostSession)
    _=bridge.process([.invitation(other,otherSecret,1.01)],now:1.01,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":1,"mask":0}"#.utf8),1.02)],now:1.02,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":2,"mask":1}"#.utf8),1.03)],now:1.03,session:&hostSession,send:sink)
    try bridge.issue(secret:secret,source:.phone,now:1.04,session:hostSession)
    var client=MobileLANSession(selection:.keys)
    let start=client.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:ns(40))
    guard case .binary(let binary)=start else{throw RemoteTouchError.invalidFrame}
    let admit=bridge.process([.invitation(peer,binary,1.05)],now:1.05,session:&hostSession,send:sink)
    #expect(admit.actions == [.acknowledge(peer,true)])
    guard case .text(let cap)=client.receive(text:"admitted",now:ns(50)) else{throw RemoteTouchError.invalidFrame}
    let capability=bridge.process([.frame(peer,cap,1.06)],now:1.06,session:&hostSession,send:sink)
    guard case .capabilities(let id,let manifest)=capability.actions.first else{throw RemoteTouchError.invalidFrame}
    #expect(id==peer)
    let response=String(decoding:try manifest.encoded(),as:UTF8.self)
    guard case .text(let neutral)=client.receive(text:response,now:ns(64)) else{throw RemoteTouchError.invalidFrame}
    let neutralACK=bridge.process([.frame(peer,neutral,1.065)],now:1.065,session:&hostSession,send:sink)
    #expect(neutralACK.actions == [.acknowledge(peer,true)])
    #expect(client.receive(text:"accepted",now:ns(80)) == .wait)
    guard case .text(let attack)=client.offer(.init(keys:1),observedAt:ns(81),now:ns(81)) else{throw RemoteTouchError.invalidFrame}
    let attackACK=bridge.process([.frame(peer,attack,1.082)],now:1.082,session:&hostSession,send:sink)
    #expect(attackACK.actions == [.acknowledge(peer,true)])
    #expect(sent.last?.groupID==phone.id && sent.last?.command.destination.number==60 && sent.last?.command.value==93)
    _=client.receive(text:"accepted",now:ns(90))
    _=client.abort()
    sent.removeAll()
    _=bridge.process([.disconnected(peer)],now:1.1,session:&hostSession,send:sink)
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.value==0)
    #expect(bridge.connectionIDs == [other])
    #expect(hostSession.boundSources == [.tablet])
}

@Test func mobileCameraAssignmentAppearsAfterNeutralAndClearsOnClose() throws {
    var session = MobileLANSession(selection: .keys)
    #expect(session.readyManifest == nil)
    _ = session.begin(trustedTLS: true, subprotocol: "tihulu-touch-v1", invitation: invitation, now: 0)
    _ = session.receive(text: "admitted", now: ns(1))
    _ = session.receive(text: try host(1 << 19), now: ns(15))
    #expect(session.readyManifest == nil)
    _ = session.receive(text: "accepted", now: ns(20))
    let manifest = try #require(session.readyManifest)
    var projection = try #require(MobileAirCaptureProjection(mode: .depthKeys, keys: manifest.piano))
    let hand = MobileAirObservation(sample: .debugSample(x: 0.9, y: 0.5, aperture: 0.5), depth: 0.4)
    for time in [0.05, 0.1] {
        let sample = projection.receive(.init(single: hand, time: time), now: time)
        let at = try #require(MobileAirCaptureFrame.nanoseconds(time))
        let action = session.offer(sample, observedAt: at, now: at)
        if time == 0.1 { #expect(try packet(action).mask == 1 << 19) }
    }
    _ = session.abort()
    #expect(session.readyManifest == nil)
}

@Test func mobileCaptureTimestampConversionRejectsInvalidAndKeepsCaptureTime() {
    #expect(MobileAirCaptureFrame.nanoseconds(12.125) == 12_125_000_000)
    for value in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
        #expect(MobileAirCaptureFrame.nanoseconds(value) == nil)
    }
}

@Test func mobileLANSessionModeChangeRequiresNewNeutralACKAndPreservesLane() throws {
    var s=MobileLANSession(selection:.keys)
    _=s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    _=s.receive(text:"admitted",now:ns(1))
    _=s.receive(text:try host(7),now:ns(15))
    _=s.receive(text:"accepted",now:ns(20))
    _=s.offer(.init(keys:1),observedAt:ns(30),now:ns(30))
    _=s.receive(text:"accepted",now:ns(40))
    #expect(try packet(s.pauseForModeChange(now:ns(45))).mask == 0)
    #expect(s.phase == .reconfiguring && s.readyManifest == nil)
    #expect(s.offer(.init(keys:2),observedAt:ns(46),now:ns(46)) == .wait)
    _=s.receive(text:"accepted",now:ns(50))
    #expect(s.phase == .ready && s.readyManifest?.piano == 7)
    #expect(s.offer(.init(keys:2),observedAt:ns(49),now:ns(51)) == .wait)
    #expect(try packet(s.offer(.init(keys:2),observedAt:ns(60),now:ns(60))).mask == 2)
}
@Test func mobileLANSessionModeChangeCannotOutliveReleaseDeadline() throws {
    var s=MobileLANSession(selection:.helper(0))
    _=s.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:0)
    _=s.receive(text:"admitted",now:ns(1))
    _=s.receive(text:try host(0,1),now:ns(15))
    _=s.receive(text:"accepted",now:ns(20))
    _=s.pauseForModeChange(now:ns(30))
    #expect(s.poll(now:ns(180)) == .close("Release overdue"))
    #expect(s.readyManifest == nil)
    #expect(s.receive(text:"accepted",now:ns(181)) == .close("Already closed"))
}

@Test func mobileLANModeChangeReleasesOnlyItsOwnGroupAndKeepsOtherPlayerBound() throws {
    let phone=PerformanceInstrumentGroup(name:"Changing phone",patch:.init(routes:[.init(id:"phone0",source:.phone,signal:.pianoKey0,destination:.init(.note,number:60),velocity:93),.init(id:"phone1",source:.phone,signal:.pianoKey1,destination:.init(.note,number:62),velocity:91)]))
    let tablet=PerformanceInstrumentGroup(name:"Independent tablet",patch:.init(routes:[.init(id:"tablet0",source:.tablet,signal:.pianoKey0,destination:.init(.note,number:64))]))
    var hostSession=try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let peer=UUID(),other=UUID(),secret=Data(repeating:0xab,count:32),otherSecret=Data(repeating:2,count:32)
    var sent:[PerformanceGroupCommand]=[]
    let sink:(PerformanceGroupCommand)->Bool={sent.append($0);return true}
    _=bridge.process([.ready],now:1,session:&hostSession,send:sink)
    try bridge.issue(secret:otherSecret,source:.tablet,now:1,session:hostSession)
    _=bridge.process([.invitation(other,otherSecret,1.01)],now:1.01,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":1,"mask":0}"#.utf8),1.02)],now:1.02,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":2,"mask":1}"#.utf8),1.03)],now:1.03,session:&hostSession,send:sink)
    #expect(sent.last?.groupID==tablet.id && sent.last?.command.value != 0)
    try bridge.issue(secret:secret,source:.phone,now:1.04,session:hostSession)
    var client=MobileLANSession(selection:.keys)
    guard case .binary(let binary)=client.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:ns(40)) else{throw RemoteTouchError.invalidFrame}
    _=bridge.process([.invitation(peer,binary,1.05)],now:1.05,session:&hostSession,send:sink)
    guard case .text(let cap)=client.receive(text:"admitted",now:ns(50)) else{throw RemoteTouchError.invalidFrame}
    let capability=bridge.process([.frame(peer,cap,1.06)],now:1.06,session:&hostSession,send:sink)
    guard case .capabilities(let id,let manifest)=capability.actions.first else{throw RemoteTouchError.invalidFrame}
    #expect(id==peer)
    let response=String(decoding:try manifest.encoded(),as:UTF8.self)
    guard case .text(let neutral)=client.receive(text:response,now:ns(64)) else{throw RemoteTouchError.invalidFrame}
    _=bridge.process([.frame(peer,neutral,1.065)],now:1.065,session:&hostSession,send:sink)
    _=client.receive(text:"accepted",now:ns(80))
    #expect(client.readyManifest?.piano==3)
    guard case .text(let attack)=client.offer(.init(keys:1),observedAt:ns(81),now:ns(81)) else{throw RemoteTouchError.invalidFrame}
    _=bridge.process([.frame(peer,attack,1.082)],now:1.082,session:&hostSession,send:sink)
    _=client.receive(text:"accepted",now:ns(90))
    sent.removeAll()
    guard case .text(let release)=client.pauseForModeChange(now:ns(95)) else{throw RemoteTouchError.invalidFrame}
    let releaseACK=bridge.process([.frame(peer,release,1.095)],now:1.095,session:&hostSession,send:sink)
    #expect(releaseACK.actions == [.acknowledge(peer,true)])
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.destination.number==60 && sent.first?.command.value==0)
    #expect(client.readyManifest==nil)
    #expect(client.offer(.init(keys:2),observedAt:ns(96),now:ns(96)) == .wait)
    _=client.receive(text:"accepted",now:ns(100))
    #expect(client.readyManifest?.piano==3)
    sent.removeAll()
    guard case .text(let next)=client.offer(.init(keys:2),observedAt:ns(110),now:ns(110)) else{throw RemoteTouchError.invalidFrame}
    let newACK=bridge.process([.frame(peer,next,1.11)],now:1.11,session:&hostSession,send:sink)
    #expect(newACK.actions == [.acknowledge(peer,true)])
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.destination.number==62 && sent.first?.command.value==91)
    #expect(bridge.connectionIDs == [peer,other])
    #expect(hostSession.boundSources == [.phone,.tablet])
    sent.removeAll()
    _=bridge.process([.disconnected(peer)],now:1.12,session:&hostSession,send:sink)
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.destination.number==62 && sent.first?.command.value==0)
    #expect(bridge.connectionIDs == [other])
    #expect(hostSession.boundSources == [.tablet])
}

@Test func mobileTouchStationarySustainAcrossActualHostGroupBridge() throws {
    let phone=PerformanceInstrumentGroup(name:"Touch phone",patch:.init(routes:[.init(id:"held",source:.phone,signal:.pianoKey0,destination:.init(.note,number:60),velocity:93)]))
    let tablet=PerformanceInstrumentGroup(name:"Other player",patch:.init(routes:[.init(id:"other",source:.tablet,signal:.pianoKey0,destination:.init(.note,number:64))]))
    var hostSession=try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let peer=UUID(),other=UUID(),secret=Data(repeating:0xab,count:32),otherSecret=Data(repeating:2,count:32)
    var sent:[PerformanceGroupCommand]=[]
    let sink:(PerformanceGroupCommand)->Bool={sent.append($0);return true}
    _=bridge.process([.ready],now:1,session:&hostSession,send:sink)
    try bridge.issue(secret:otherSecret,source:.tablet,now:1,session:hostSession)
    _=bridge.process([.invitation(other,otherSecret,1.01)],now:1.01,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":1,"mask":0}"#.utf8),1.02)],now:1.02,session:&hostSession,send:sink)
    _=bridge.process([.frame(other,Data(#"{"kind":"pianoKeys","version":5,"sequence":2,"mask":1}"#.utf8),1.03)],now:1.03,session:&hostSession,send:sink)
    try bridge.issue(secret:secret,source:.phone,now:1.04,session:hostSession)
    var client=MobileLANSession(selection:.keys)
    guard case .binary(let binary)=client.begin(trustedTLS:true,subprotocol:"tihulu-touch-v1",invitation:invitation,now:ns(40)) else{throw RemoteTouchError.invalidFrame}
    _=bridge.process([.invitation(peer,binary,1.05)],now:1.05,session:&hostSession,send:sink)
    guard case .text(let cap)=client.receive(text:"admitted",now:ns(50)) else{throw RemoteTouchError.invalidFrame}
    let capability=bridge.process([.frame(peer,cap,1.06)],now:1.06,session:&hostSession,send:sink)
    guard case .capabilities(_,let manifest)=capability.actions.first else{throw RemoteTouchError.invalidFrame}
    guard case .text(let neutral)=client.receive(text:String(decoding:try manifest.encoded(),as:UTF8.self),now:ns(64)) else{throw RemoteTouchError.invalidFrame}
    _=bridge.process([.frame(peer,neutral,1.065)],now:1.065,session:&hostSession,send:sink)
    _=client.receive(text:"accepted",now:ns(80))
    var lease=try #require(MobileTouchLiveLease(authorized:manifest.piano,armedAt:ns(81)))
    let initial=lease.event(.began,contacts:[.init(id:0,x:0.5)],now:ns(82),ownerActive:true)
    let down=try #require(initial)
    guard case .text(let attack)=client.offer(down.output,observedAt:down.ownerAt,now:down.ownerAt) else{throw RemoteTouchError.invalidFrame}
    sent.removeAll()
    let attackACK=bridge.process([.frame(peer,attack,1.082)],now:1.082,session:&hostSession,send:sink)
    #expect(attackACK.actions == [.acknowledge(peer,true)])
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.value==93)
    _=client.receive(text:"accepted",now:ns(87))
    sent.removeAll()
    for tick:Int64 in [132,182,232,282,332] {
        let next=lease.pulse(now:ns(tick),ownerActive:true)
        let pulse=try #require(next)
        guard case .text(let refresh)=client.offer(pulse.output,observedAt:pulse.ownerAt,now:pulse.ownerAt) else{throw RemoteTouchError.invalidFrame}
        let time=1+Double(tick)/1000
        let ack=bridge.process([.frame(peer,refresh,time)],now:time,session:&hostSession,send:sink)
        #expect(ack.actions == [.acknowledge(peer,true)])
        _=client.receive(text:"accepted",now:ns(tick+5))
    }
    #expect(sent.isEmpty)
    let ended=lease.event(.ended,contacts:[],now:ns(350),ownerActive:true)
    let up=try #require(ended)
    guard case .text(let release)=client.offer(up.output,observedAt:up.ownerAt,now:up.ownerAt) else{throw RemoteTouchError.invalidFrame}
    let ack=bridge.process([.frame(peer,release,1.35)],now:1.35,session:&hostSession,send:sink)
    #expect(ack.actions == [.acknowledge(peer,true)])
    #expect(sent.count==1 && sent.first?.groupID==phone.id && sent.first?.command.destination.number==60 && sent.first?.command.value==0)
    _=client.receive(text:"accepted",now:ns(355))
    #expect(bridge.connectionIDs == [peer,other])
    #expect(hostSession.boundSources == [.phone,.tablet])
}
