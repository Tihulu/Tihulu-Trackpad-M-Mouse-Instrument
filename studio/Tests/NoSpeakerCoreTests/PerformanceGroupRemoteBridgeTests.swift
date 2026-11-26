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

@Test func groupRemoteIncompleteMetadataExpiresOnEmptyWatchdogTick() throws {
    let phone=groupRemoteFixture(.phone,.contact,60)
    let tablet=groupRemoteFixture(.tablet,.pianoKey0,64)
    var session=try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let a=UUID(),b=UUID(),secretA=Data(repeating:1,count:32),secretB=Data(repeating:2,count:32)
    let sink:(PerformanceGroupCommand)->Bool={ _ in Issue.record("Unexpected MIDI during metadata");return true }
    _=bridge.process([.ready],now:0,session:&session,send:sink)
    try bridge.issue(secret:secretA,source:.phone,now:0,session:session)
    _=bridge.process([.invitation(a,secretA,0)],now:0,session:&session,send:sink)
    try bridge.issue(secret:secretB,source:.tablet,now:0,session:session)
    _=bridge.process([.invitation(b,secretB,0)],now:0,session:&session,send:sink)
    _=bridge.process([.frame(a,groupRemoteWire("capabilities",7,1),0.25)],now:0.25,session:&session,send:sink)
    // Both connections remain below the two-second idle deadline.
    for i in 1...10 {
        let now=Double(i)
        let batch=bridge.process([.frame(a,groupRemoteWire("heartbeat",1,i+1),now),
                                  .frame(b,groupRemoteWire("heartbeat",1,i),now)],now:now,session:&session,send:sink)
        #expect(batch.actions==[.acknowledge(a,true),.acknowledge(b,true)])
    }
    let before=bridge.process([],now:10.249,session:&session,send:sink)
    #expect(before.actions.isEmpty && bridge.connectionIDs==[a,b])
    let boundary=bridge.process([],now:10.25,session:&session,send:sink)
    #expect(boundary.actions==[.revoke(a)] && bridge.connectionIDs==[b])
    #expect(session.boundSources==[.tablet])
    let replay=bridge.process([.frame(a,groupRemoteWire("mapping",8,12,",\"page\":0"),10.26)],now:10.26,session:&session,send:sink)
    #expect(replay.actions==[.acknowledge(a,false)] && session.boundSources==[.tablet])
}

@Test func groupRemoteOptionalMetadataDoesNotExpireAfterPerformanceStarts() throws {
    let group=groupRemoteFixture(.phone,.contact,60)
    var session=try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
    var bridge=PerformanceGroupRemoteBridge()
    let peer=UUID(),secret=Data(repeating:3,count:32)
    let sink:(PerformanceGroupCommand)->Bool={ _ in Issue.record("Unexpected MIDI");return true }
    _=bridge.process([.ready],now:0,session:&session,send:sink)
    try bridge.issue(secret:secret,source:.phone,now:0,session:session)
    _=bridge.process([.invitation(peer,secret,0)],now:0,session:&session,send:sink)
    _=bridge.process([.frame(peer,groupRemoteWire("capabilities",7,1),0.25)],now:0.25,session:&session,send:sink)
    _=bridge.process([.frame(peer,groupRemoteWire("release",1,2),0.5)],now:0.5,session:&session,send:sink)
    for i in 1...11 {
        let now=Double(i)
        let batch=bridge.process([.frame(peer,groupRemoteWire("heartbeat",1,i+2),now)],now:now,session:&session,send:sink)
        #expect(batch.actions==[.acknowledge(peer,true)])
    }
    #expect(bridge.connectionIDs==[peer] && session.boundSources==[.phone])
}

@Test func groupRemoteLabelLastPageMustFinishBeforeOriginalMetadataDeadline() throws {
    let signals=Array(RemotePiano.keySignals.prefix(12))
    let group=PerformanceInstrumentGroup(name:"Keys",patch:.init(routes:signals.enumerated().map { index,signal in
        .init(id:"key-\(index)",source:.phone,signal:signal,destination:.init(.note,number:48+index))
    },performanceLayout:.init(widgets:signals.enumerated().map { index,signal in
        .init(source:.phone,signal:signal,label:"Key \(index)")
    })))
    for completeInTime in [true,false] {
        var session=try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
        var bridge=PerformanceGroupRemoteBridge()
        let peer=UUID(),secret=Data(repeating:5,count:32)
        let sink:(PerformanceGroupCommand)->Bool={ _ in Issue.record("Unexpected MIDI");return true }
        _=bridge.process([.ready],now:0,session:&session,send:sink)
        try bridge.issue(secret:secret,source:.phone,now:0,session:session,shareLabels:true)
        _=bridge.process([.invitation(peer,secret,0)],now:0,session:&session,send:sink)
        _=bridge.process([.frame(peer,groupRemoteWire("capabilities",7,1),0.25)],now:0.25,session:&session,send:sink)
        _=bridge.process([.frame(peer,groupRemoteWire("mapping",8,2,",\"page\":0"),0.5)],now:0.5,session:&session,send:sink)
        for page in 0..<11 {
            let now=0.75+Double(page)*0.9
            let batch=bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,page+3,",\"page\":\(page)"),now)],now:now,session:&session,send:sink)
            #expect(batch.actions.count==1)
            if case .some(.mappingLabels(let id,let value))=batch.actions.first {
                #expect(id==peer && value.page==page && value.pages==12 && value.total==12)
            } else { Issue.record("Missing consented label page") }
        }
        let now=completeInTime ? 10.249 : 10.25
        let final=bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,14,",\"page\":11"),now)],now:now,session:&session,send:sink)
        if completeInTime {
            #expect(final.actions.count==1)
            if case .some(.mappingLabels(let id,let value))=final.actions.first {
                #expect(id==peer && value.page==11 && value.rows.count==1 && value.total==12)
            } else { Issue.record("Missing final page") }
            let play=bridge.process([.frame(peer,groupRemoteWire("pianoKeys",5,15,",\"mask\":0"),10.26)],now:10.26,session:&session,send:sink)
            #expect(play.actions==[.acknowledge(peer,true)])
            let replay=bridge.process([.frame(peer,groupRemoteWire("mappingLabels",8,16,",\"page\":0"),10.27)],now:10.27,session:&session,send:sink)
            #expect(replay.actions==[.acknowledge(peer,false)])
        } else {
            #expect(final.actions==[.revoke(peer),.acknowledge(peer,false)])
        }
        #expect(bridge.connectionIDs.isEmpty && session.boundSources.isEmpty)
    }
}

@Test func remoteGroupBatchRechecksReceiptAfterEarlierSynchronousAttack() throws {
    for stall in [false,true] {
        let phone=groupRemoteFixture(.phone,.drumPad1,36)
        let tablet=groupRemoteFixture(.tablet,.pianoKey0,60)
        var session=try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet]),allowRemote:true)
        var bridge=PerformanceGroupRemoteBridge()
        let a=UUID(),b=UUID()
        let sa=Data(repeating:1,count:32),sb=Data(repeating:2,count:32)
        var sent:[PerformanceGroupCommand]=[]
        var now=1.05
        let sink:(PerformanceGroupCommand)->Bool = {
            sent.append($0)
            if stall && $0.groupID==phone.id && $0.command.value>0 { now=1.16 }
            return true
        }
        _=bridge.process([.ready],now:1,session:&session,send:sink)
        try bridge.issue(secret:sa,source:.phone,now:1,session:session)
        _=bridge.process([.invitation(a,sa,1.01)],now:1.01,session:&session,send:sink)
        try bridge.issue(secret:sb,source:.tablet,now:1.02,session:session)
        _=bridge.process([.invitation(b,sb,1.03)],now:1.03,session:&session,send:sink)
        _=bridge.process([.frame(a,groupRemoteWire("drumPads",4,1,",\"mask\":0"),1.04),
                          .frame(b,groupRemoteWire("pianoKeys",5,1,",\"mask\":0"),1.04)],
                         now:1.04,session:&session,send:sink)
        let result=bridge.process([.frame(a,groupRemoteWire("drumPads",4,2,",\"mask\":1"),1.05),
                                   .frame(b,groupRemoteWire("pianoKeys",5,2,",\"mask\":1"),1.05)],
                                  now:1.05,refreshNow:{now},session:&session,send:sink)
        #expect(sent.filter{$0.command.value>0}.map(\.groupID) == (stall ? [phone.id] : [phone.id,tablet.id]))
        #expect(result.actions == [.acknowledge(a,!stall),.acknowledge(b,!stall)])
        #expect(bridge.connectionIDs == (stall ? [] : [a,b]))
        if stall {
            #expect(sent.count == 2 && sent.last?.groupID == phone.id && sent.last?.command.value == 0)
            #expect(result.reports.contains(where:{ $0.admissionExpired }))
        }
        #expect(!session.retired)
    }
}

@Test func remoteGroupSessionRechecksReceiptAfterItsOwnSynchronousExpiryCleanup() throws {
    for stall in [false,true] {
        let local=groupRemoteFixture(.gamepad1,.padA,64)
        let phone=groupRemoteFixture(.phone,.contact,60)
        var session=try PerformanceGroupGamepadSession(profile:.init(groups:[local,phone]),allowRemote:true)
        let localToken=try session.bind(.gamepad1,now:1)
        let neutral=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
        var buttons=Array(repeating:0.0,count:12)
        buttons[0]=1
        let held=try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
        _=session.receive(.gamepad1,token:localToken,frame:neutral,now:1,send:{_ in true})
        _=session.receive(.gamepad1,token:localToken,frame:held,now:1.01,send:{_ in true})
        let phoneToken=try session.bind(.phone,now:1.2)
        _=session.receiveRemote(.phone,token:phoneToken,bytes:groupRemoteWire("release",1,1),
                                hostTime:1.3,now:1.3,send:{_ in true})
        var now=1.37
        var sent:[PerformanceGroupCommand]=[]
        let result=session.receiveRemote(.phone,token:phoneToken,
            bytes:groupRemoteWire("touch",1,2,",\"x\":0.5,\"y\":0.5"),
            hostTime:1.36,now:now,refreshNow:{now},send:{command in
                sent.append(command)
                if stall && command.groupID==local.id { now=1.47 }
                return true
            })
        #expect(sent.first?.groupID==local.id && sent.first?.command.value==0)
        #expect(sent.filter{$0.command.value>0}.map(\.groupID) == (stall ? [] : [phone.id]))
        #expect(result.status == (stall ? .lost : .delivered))
        #expect(session.boundSources.contains(.phone) == !stall)
        #expect(!session.retired)
    }
}


@Test func remoteGroupReceiptExpiryRejectsRemainingChordAndCleansAttemptedNote() throws {
    let phone = PerformanceInstrumentGroup(name:"Phone chord",patch:.init(routes:[
        .init(id:"one",source:.phone,signal:.drumPad1,destination:.init(.note,number:36)),
        .init(id:"two",source:.phone,signal:.drumPad2,destination:.init(.note,number:38))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone]),allowRemote:true)
    let token = try session.bind(.phone,now:1)
    _ = session.receiveRemote(.phone,token:token,bytes:groupRemoteWire("drumPads",4,1,",\"mask\":0"),
                              hostTime:1.01,now:1.01,send:{_ in true})
    var now = 1.02
    var sent:[PerformanceGroupCommand] = []
    let result = session.receiveRemote(.phone,token:token,bytes:groupRemoteWire("drumPads",4,2,",\"mask\":3"),
                                       hostTime:1.02,now:now,refreshNow:{now},send:{
        sent.append($0)
        if $0.command.value > 0 { now = 1.13 }
        return true
    })
    #expect(result.status == .lost && !session.boundSources.contains(.phone))
    #expect(result.reports.contains(where:{ $0.admissionExpired }))
    #expect(sent.count == 2 && sent.first?.command.value == 100 && sent.last?.command.value == 0)
    #expect(sent.first?.command.destination == sent.last?.command.destination)
    #expect(session.pendingCleanup.isEmpty && !session.retired)
}


@Test func remoteGroupLateFinalReleaseCannotRearmOrKeepAuthentication() throws {
    let group = groupRemoteFixture(.phone,.drumPad1,36)
    var state = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
    let token = try state.bind(.phone,now:1)
    _ = state.receiveRemote(.phone,token:token,bytes:groupRemoteWire("drumPads",4,1,",\"mask\":0"),
                            hostTime:1.01,now:1.01,send:{_ in true})
    _ = state.receiveRemote(.phone,token:token,bytes:groupRemoteWire("drumPads",4,2,",\"mask\":1"),
                            hostTime:1.02,now:1.02,send:{_ in true})
    var now = 1.03
    var sent:[PerformanceGroupCommand] = []
    let result = state.receiveRemote(.phone,token:token,bytes:groupRemoteWire("drumPads",4,3,",\"mask\":0"),
                                     hostTime:now,now:now,refreshNow:{now},send:{sent.append($0);now=1.14;return true})
    #expect(result.status == .lost && !state.boundSources.contains(.phone))
    #expect(sent.count == 1 && sent.first?.command.value == 0 && state.pendingCleanup.isEmpty)
}
