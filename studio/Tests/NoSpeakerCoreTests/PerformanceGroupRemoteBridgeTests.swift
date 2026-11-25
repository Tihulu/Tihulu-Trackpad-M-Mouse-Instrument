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


@Test func remoteGroupBridgeReconcilesExpiryAndDisconnectWithoutRestoringDepartingOwner() throws {
    let target = SensorDestination(.controlChange,number:74)
    let group = PerformanceInstrumentGroup(name:"Shared CC",patch:.init(routes:[
        .init(id:"high",source:.phone,signal:.x,destination:target,priority:10),
        .init(id:"low",source:.tablet,signal:.x,destination:target,priority:0)
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
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
    _ = bridge.process([.frame(a,groupRemoteWire("release",1,1),1.04),
                        .frame(b,groupRemoteWire("release",1,1),1.04)],now:1.04,session:&session,send:sink)
    _ = bridge.process([.frame(a,groupRemoteWire("touch",1,2,",\"x\":1,\"y\":0.5"),1.05)],now:1.05,session:&session,send:sink)
    _ = bridge.process([.frame(b,groupRemoteWire("touch",1,2,",\"x\":0.5,\"y\":0.5"),1.20)],now:1.20,session:&session,send:sink)
    #expect(sent.last?.command.value == 127)
    sent.removeAll()
    let result = bridge.process([.disconnected(b)],now:1.41,session:&session,send:sink)
    #expect(sent.map(\.command.value) == [0])
    #expect(result.actions == [.revoke(a)])
    #expect(bridge.connectionIDs.isEmpty && session.boundSources.isEmpty)
}


@Test func remoteGroupSlotReplacementDoesNotStealOtherPendingInvitation() throws {
    let phone = groupRemoteFixture(.phone,.drumPad1,36)
    let tablet = groupRemoteFixture(.tablet,.pianoKey0,60)
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    let a = UUID(), b = UUID(), duplicate = UUID()
    let secretA = Data(repeating:1,count:32), secretB = Data(repeating:2,count:32)
    let sink:(PerformanceGroupCommand)->Bool = { _ in true }
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    try bridge.issue(secret:secretA,source:.phone,now:1,session:session)
    _ = bridge.process([.invitation(a,secretA,1.01)],now:1.01,session:&session,send:sink)
    #expect(bridge.connectionSlots == [a:.phone])
    try bridge.issue(secret:secretB,source:.tablet,now:1.02,session:session)
    #expect(throws:RemoteTouchError.unavailable) {
        try bridge.issue(secret:Data(repeating:3,count:32),source:.phone,now:1.03,session:session)
    }
    let result = bridge.process([.disconnected(a),.invitation(b,secretB,1.04)],now:1.04,session:&session,send:sink)
    #expect(result.actions == [.acknowledge(b,true)])
    #expect(bridge.connectionSlots == [b:.tablet])
    #expect(session.boundSources == [.tablet])
    let replay = bridge.process([.invitation(duplicate,secretB,1.05)],now:1.05,session:&session,send:sink)
    #expect(replay.actions == [.acknowledge(duplicate,false)])
    #expect(bridge.connectionSlots == [b:.tablet])
    _ = bridge.stop(session:&session,send:sink)
    #expect(bridge.connectionSlots.isEmpty && session.boundSources.isEmpty)
}


@Test func groupRemoteLabelConsentIsFrozenScopedAndRedactedByDefault() throws {
    var phone = groupRemoteFixture(.phone2,.drumPad1,36)
    phone.patch.performanceLayout = .init(widgets:[
        .init(source:.phone2,signal:.drumPad1,label:"Kick <safe>"),
        .init(source:.phone2,signal:.drumPad2,label:"Dormant"),
        .init(source:.tablet2,signal:.pianoKey0,label:"Private other")
    ])
    var tablet = groupRemoteFixture(.tablet2,.pianoKey0,60)
    tablet.patch.performanceLayout = .init(widgets:[.init(source:.tablet2,signal:.pianoKey0,label:"Keys")])
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    let sink:(PerformanceGroupCommand)->Bool = {_ in true}
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    #expect(session.remoteLabelPreview(.phone2) == ["drumPad1 · Kick <safe>"])
    #expect(session.remoteLabelPreview(.tablet2) == ["pianoKey0 · Keys"])
    #expect(session.remoteLabelPreview(.gamepad1).isEmpty)
    for (i,consent) in [false,true].enumerated() {
        let time = 1+Double(i)
        let peer = UUID(), secret = Data(repeating:UInt8(i+1),count:32)
        try bridge.issue(secret:secret,source:.phone2,now:time,session:session,shareLabels:consent)
        _ = bridge.process([.invitation(peer,secret,time+0.01)],now:time+0.01,session:&session,send:sink)
        _ = bridge.process([.frame(peer,groupRemoteWire("capabilities",7,1),time+0.02)],now:time+0.02,session:&session,send:sink)
        let mapping = bridge.process([.frame(peer,groupRemoteWire("mapping",8,2,",\"page\":0"),time+0.03)],now:time+0.03,session:&session,send:sink)
        #expect(mapping.actions == [.mapping(peer,.init(sequence:2,page:0,pages:1,total:0,detail:false,rows:[]))])
        let labels = bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,3,",\"page\":0"),time+0.04)],now:time+0.04,session:&session,send:sink)
        let expected:[RemoteMappingLabel] = consent ? [.init(signal:9,text:"Kick <safe>")] : []
        #expect(labels.actions == [.mappingLabels(peer,.init(sequence:3,page:0,pages:1,total:expected.count,rows:expected))])
        let repeatPage = bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,4,",\"page\":0"),time+0.05)],now:time+0.05,session:&session,send:sink)
        #expect(repeatPage.actions == [.acknowledge(peer,false)])
        #expect(session.boundSources.isEmpty)
    }
}

@Test func groupRemoteLabelProjectionOmitsConflictsAndInvalidText() throws {
    var first = groupRemoteFixture(.phone,.drumPad1,36)
    first.patch.routes.append(.init(id:"second",source:.phone,signal:.drumPad2,destination:.init(.note,number:38)))
    first.patch.performanceLayout = .init(widgets:[
        .init(source:.phone,signal:.drumPad1,label:"First"),
        .init(source:.phone,signal:.drumPad2,label:"   ")
    ])
    var second = groupRemoteFixture(.phone,.drumPad1,40)
    second.patch.performanceLayout = .init(widgets:[.init(source:.phone,signal:.drumPad1,label:"Second")])
    let profile = PerformanceGroupProfile(groups:[first,second])
    #expect(profile.isValid)
    #expect(!RemoteMappingLabel.permits("bad\u{202E}text"))
    #expect(!RemoteMappingLabel.permits("   "))
    var invalid = profile
    invalid.groups[0].patch.performanceLayout?.widgets[1].label = "bad\u{202E}text"
    #expect(!invalid.isValid)
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.unsupportedProfile) {
        try PerformanceGroupGamepadSession(profile:invalid,allowLayering:true,allowRemote:true)
    }
    let session = try PerformanceGroupGamepadSession(profile:profile,allowLayering:true,allowRemote:true)
    #expect(session.groupRemoteLabels(.phone).isEmpty)
    #expect(session.groupRemoteLabels(.tablet).isEmpty)
}

@Test func groupRemoteLabelSequenceRejectsEarlySkippedAndMidPerformanceRequests() throws {
    var group = groupRemoteFixture(.phone,.drumPad1,36)
    group.patch.routes.append(.init(id:"second",source:.phone,signal:.drumPad2,destination:.init(.note,number:38)))
    group.patch.performanceLayout = .init(widgets:[
        .init(source:.phone,signal:.drumPad1,label:"Kick"),
        .init(source:.phone,signal:.drumPad2,label:"Snare")
    ])
    for scenario in 0..<3 {
        var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
        var bridge = PerformanceGroupRemoteBridge()
        let sink:(PerformanceGroupCommand)->Bool = {_ in true}
        let peer = UUID(), secret = Data(repeating:3,count:32)
        _ = bridge.process([.ready],now:1,session:&session,send:sink)
        try bridge.issue(secret:secret,source:.phone,now:1,session:session,shareLabels:true)
        _ = bridge.process([.invitation(peer,secret,1.01)],now:1.01,session:&session,send:sink)
        _ = bridge.process([.frame(peer,groupRemoteWire("capabilities",7,1),1.02)],now:1.02,session:&session,send:sink)
        if scenario != 0 {
            _ = bridge.process([.frame(peer,groupRemoteWire("mapping",8,2,",\"page\":0"),1.03)],now:1.03,session:&session,send:sink)
        }
        if scenario == 2 {
            _ = bridge.process([.frame(peer,groupRemoteWire("drumPads",4,3,",\"mask\":0"),1.04)],now:1.04,session:&session,send:sink)
        }
        let page = scenario == 1 ? 1 : 0
        let result = bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,4,",\"page\":\(page)"),1.05)],now:1.05,session:&session,send:sink)
        #expect(result.actions == [.acknowledge(peer,false)])
        #expect(bridge.connectionIDs.isEmpty)
    }
}

@Test func groupRemoteSingleParsePreservesRateFenceInBridgeAndRawAPI() throws {
    let phone = groupRemoteFixture(.phone,.contact,60)
    let profile = PerformanceGroupProfile(groups:[phone])
    var direct=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
    var session=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let peer=UUID(),secret=Data(repeating:5,count:32)
    let token=try direct.bind(.phone,now:1)
    let sink:(PerformanceGroupCommand)->Bool = { _ in Issue.record("Unexpected musical output"); return true }
    _=bridge.process([.ready],now:1,session:&session,send:sink)
    try bridge.issue(secret:secret,source:.phone,now:1,session:session)
    _=bridge.process([.invitation(peer,secret,1)],now:1,session:&session,send:sink)
    for index in 1...91 {
        let bytes=groupRemoteWire("heartbeat",1,index)
        let now=1+Double(index)/1000
        let raw=direct.receiveRemote(.phone,token:token,bytes:bytes,hostTime:now,now:now,send:sink)
        let wrapped=bridge.process([.frame(peer,bytes,now)],now:now,session:&session,send:sink)
        #expect(raw.status == (index<=90 ? .waitingForNeutral : .lost))
        #expect(wrapped.actions == [.acknowledge(peer,index<=90)])
    }
    #expect(direct.boundSources.isEmpty && session.boundSources.isEmpty && bridge.connectionIDs.isEmpty)
}

@Test func groupRemoteSingleParseRejectsMalformedWireAndReleasesOnlyOwnedNote() throws {
    let phone=groupRemoteFixture(.phone,.contact,60)
    let profile=PerformanceGroupProfile(groups:[phone])
    let invalid:[Data] = [
        Data(#"{"kind":"touch","version":1,"sequence":3,"x":0.5,"x":0.6,"y":0.5}"#.utf8),
        Data(#"{"kind":"touch","version":1,"sequence":3,"x":0.5,"y":0.5,"extra":1}"#.utf8),
        groupRemoteWire("touch",1,2,",\"x\":0.5,\"y\":0.5"),
        Data(repeating:32,count:RemoteTouchFrame.maximumBytes+1)
    ]
    for bytes in invalid {
        var direct=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
        var session=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
        var bridge=PerformanceGroupRemoteBridge()
        let peer=UUID(),secret=Data(repeating:7,count:32),token=try direct.bind(.phone,now:1)
        var a:[PerformanceGroupCommand]=[], b:[PerformanceGroupCommand]=[]
        let rawSink:(PerformanceGroupCommand)->Bool={a.append($0);return true}
        let bridgeSink:(PerformanceGroupCommand)->Bool={b.append($0);return true}
        _=bridge.process([.ready],now:1,session:&session,send:bridgeSink)
        try bridge.issue(secret:secret,source:.phone,now:1,session:session)
        _=bridge.process([.invitation(peer,secret,1)],now:1,session:&session,send:bridgeSink)
        for (frame,now) in [(groupRemoteWire("release",1,1),1.01),
                            (groupRemoteWire("touch",1,2,",\"x\":0.5,\"y\":0.5"),1.02),
                            (bytes,1.03)] {
            _=direct.receiveRemote(.phone,token:token,bytes:frame,hostTime:now,now:now,send:rawSink)
            _=bridge.process([.frame(peer,frame,now)],now:now,session:&session,send:bridgeSink)
        }
        #expect(a==b && a.count==2 && (a.first?.command.value ?? 0) > 0 && a.last?.command.value==0)
        #expect(direct.boundSources.isEmpty && session.boundSources.isEmpty && bridge.connectionIDs.isEmpty)
    }
}
