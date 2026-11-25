import Foundation
import Testing
@testable import NoSpeakerCore

private func groupRemoteWire(_ kind:String,_ version:Int,_ sequence:Int,_ extra:String = "") -> Data {
    Data("{\"kind\":\"\(kind)\",\"version\":\(version),\"sequence\":\(sequence)\(extra)}".utf8)
}

private func groupRemoteFixture(_ source:SensorSource,_ signal:SensorSignal,_ note:Int) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[.init(id:"note",source:source,signal:signal,destination:.init(.note,number:note))]))
}

@Test func remoteGroupBridgeOneShotPairingAndRedactedCapabilities() throws {
    let phone = groupRemoteFixture(.phone,.drumPad1,36)
    let tablet = groupRemoteFixture(.tablet,.pianoKey0,60)
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    let secret = Data(repeating:42,count:32)
    let id = UUID(), intruder = UUID()
    #expect(throws:RemoteTouchError.unavailable) {
        try bridge.issue(secret:secret,source:.phone,now:1,session:session)
    }
    _ = bridge.process([.ready],now:1,session:&session,send:{ _ in true })
    try bridge.issue(secret:secret,source:.phone,now:1,session:session)
    let early = bridge.process([.invitation(intruder,secret,0.99)],now:1,session:&session,send:{ _ in true })
    #expect(early.actions == [.acknowledge(intruder,false)])
    let admitted = bridge.process([.invitation(id,secret,1.01)],now:1.01,session:&session,send:{ _ in true })
    #expect(admitted.actions == [.acknowledge(id,true)])
    let replay = bridge.process([.invitation(intruder,secret,1.02)],now:1.02,session:&session,send:{ _ in true })
    #expect(replay.actions == [.acknowledge(intruder,false)])
    #expect(bridge.connectionIDs == [id])
    let capabilities = bridge.process([.frame(id,groupRemoteWire("capabilities",7,1),1.03)],now:1.03,session:&session,send:{ _ in true })
    #expect(capabilities.actions == [.capabilities(id,.init(touch:false,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:1,piano:0,pedals:0))])
    let metadata = bridge.process([.frame(id,groupRemoteWire("mapping",8,2,",\"page\":0"),1.04)],now:1.04,session:&session,send:{ _ in true })
    #expect(metadata.actions == [.mapping(id,.init(sequence:2,page:0,pages:1,total:0,detail:false,rows:[]))])
    let duplicate = bridge.process([.frame(id,groupRemoteWire("mapping",8,3,",\"page\":0"),1.05)],now:1.05,session:&session,send:{ _ in true })
    #expect(duplicate.actions == [.acknowledge(id,false)])
    #expect(session.boundSources.isEmpty)
}

@Test func remoteGroupBridgeDisconnectSuppressesQueuedOnsetAndPreservesOtherSource() throws {
    let phone = groupRemoteFixture(.phone,.drumPad1,36)
    let tablet = groupRemoteFixture(.tablet,.pianoKey0,60)
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    let a = UUID(), b = UUID()
    let secretA = Data(repeating:1,count:32), secretB = Data(repeating:2,count:32)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0); return true }
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    try bridge.issue(secret:secretA,source:.phone,now:1,session:session)
    _ = bridge.process([.invitation(a,secretA,1.01)],now:1.01,session:&session,send:sink)
    try bridge.issue(secret:secretB,source:.tablet,now:1.02,session:session)
    _ = bridge.process([.invitation(b,secretB,1.03)],now:1.03,session:&session,send:sink)
    _ = bridge.process([.frame(a,groupRemoteWire("drumPads",4,1,",\"mask\":0"),1.04),.frame(b,groupRemoteWire("pianoKeys",5,1,",\"mask\":0"),1.04)],now:1.04,session:&session,send:sink)
    _ = bridge.process([.frame(b,groupRemoteWire("pianoKeys",5,2,",\"mask\":1"),1.05)],now:1.05,session:&session,send:sink)
    #expect(sent.count == 1 && sent.first?.groupID == tablet.id)
    sent.removeAll()
    let result = bridge.process([.frame(a,groupRemoteWire("drumPads",4,2,",\"mask\":1"),1.06),.disconnected(a)],now:1.06,session:&session,send:sink)
    #expect(result.actions == [.acknowledge(a,false)])
    #expect(sent.isEmpty && bridge.connectionIDs == [b])
    let stopped = bridge.stop(session:&session,send:sink)
    #expect(stopped.actions == [.stop])
    #expect(sent.count == 1 && sent.first?.groupID == tablet.id && sent.first?.command.value == 0)
    #expect(!session.retired && session.boundSources.isEmpty)
}

@Test func remoteGroupBridgeExpiresBeforeLateFrameAndFaultRetiresRemoteOnly() throws {
    let phone = groupRemoteFixture(.phone,.contact,60)
    let local = groupRemoteFixture(.gamepad1,.padA,64)
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,local]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    let token = try session.bind(.gamepad1,now:1)
    let id = UUID(), secret = Data(repeating:3,count:32)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0); return true }
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    try bridge.issue(secret:secret,source:.phone,now:1,session:session)
    _ = bridge.process([.invitation(id,secret,1.01)],now:1.01,session:&session,send:sink)
    _ = bridge.process([.frame(id,groupRemoteWire("release",1,1),1.02)],now:1.02,session:&session,send:sink)
    _ = bridge.process([.frame(id,groupRemoteWire("touch",1,2,",\"x\":0.5,\"y\":0.5"),1.03)],now:1.03,session:&session,send:sink)
    sent.removeAll()
    let expired = bridge.process([.frame(id,groupRemoteWire("touch",1,3,",\"x\":0.5,\"y\":0.5"),1.39)],now:1.39,session:&session,send:sink)
    #expect(expired.actions == [.revoke(id),.acknowledge(id,false)])
    #expect(sent.count == 1 && sent.first?.groupID == phone.id && sent.first?.command.value == 0)
    #expect(bridge.connectionIDs.isEmpty)
    let fault = bridge.process([.fault],now:1.4,session:&session,send:sink)
    #expect(fault.fault && fault.actions == [.stop])
    #expect(session.boundSources == [.gamepad1] && !session.retired)
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    let stillBound = session.receive(.gamepad1,token:token,frame:neutral,now:1.41,send:sink)
    #expect(stillBound.status == .ready)
}
