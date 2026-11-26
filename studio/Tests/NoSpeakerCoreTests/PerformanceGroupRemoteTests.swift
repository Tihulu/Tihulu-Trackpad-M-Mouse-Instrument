import Foundation
import Testing
@testable import NoSpeakerCore

private func wire(_ kind:String,_ version:Int,_ sequence:Int,_ extra:String = "") -> Data {
    Data("{\"kind\":\"\(kind)\",\"version\":\(version),\"sequence\":\(sequence)\(extra)}".utf8)
}

private func remoteGroup(_ source:SensorSource,_ signal:SensorSignal,_ target:SensorDestination) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[.init(id:"remote",source:source,signal:signal,destination:target)]))
}

@Test func groupRemoteOptInBoundsMixedModesAndRejectsUnsafeGain() throws {
    var a = remoteGroup(.phone,.contact,.init(.note,number:60))
    let profile = PerformanceGroupProfile(groups:[a])
    #expect(!PerformanceGroupGamepadSession.supports(profile))
    #expect(PerformanceGroupGamepadSession.supports(profile,allowRemote:true))
    a.patch.routes.append(.init(id:"drum",source:.phone,signal:.drumPad1,destination:.init(.note,number:36)))
    #expect(PerformanceGroupGamepadSession.supports(.init(groups:[a]),allowRemote:true))
    a.patch.routes.append(.init(id:"piano",source:.phone,signal:.pianoKey0,destination:.init(.note,number:64)))
    #expect(PerformanceGroupGamepadSession.supports(.init(groups:[a]),allowRemote:true))
    a.patch.routes.append(.init(id:"pedal",source:.phone,signal:.pedalSustain,destination:.init(.sustain)))
    #expect(PerformanceGroupGamepadSession.supports(.init(groups:[a]),allowRemote:true))
    let gain = remoteGroup(.tablet,.pedalVolume,.init(.controlChange,number:7))
    #expect(!PerformanceGroupGamepadSession.supports(.init(groups:[gain]),allowRemote:true))
}

@Test func groupRemoteNeutralAndScopedExpiryPreserveLocalSibling() throws {
    let phone = remoteGroup(.phone,.contact,.init(.note,number:60))
    let tablet = remoteGroup(.tablet,.drumPad1,.init(.note,channel:9,number:36))
    let local = remoteGroup(.gamepad1,.padA,.init(.note,number:64))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone,tablet,local]),allowRemote:true)
    let p = try session.bind(.phone,now:0)
    let t = try session.bind(.tablet,now:0)
    let g = try session.bind(.gamepad1,now:0)
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12); buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    let held = session.receiveRemote(.phone,token:p,bytes:wire("touch",1,1,",\"x\":0.5,\"y\":0.5"),hostTime:0,now:0,send:sink)
    #expect(held.status == .waitingForNeutral && events.isEmpty)
    _ = session.receiveRemote(.phone,token:p,bytes:wire("release",1,2),hostTime:0.01,now:0.01,send:sink)
    _ = session.receiveRemote(.tablet,token:t,bytes:wire("drumPads",4,1,",\"mask\":0"),hostTime:0.01,now:0.01,send:sink)
    _ = session.receive(.gamepad1,token:g,frame:neutral,now:0.01,send:sink)
    _ = session.receiveRemote(.phone,token:p,bytes:wire("touch",1,3,",\"x\":0.5,\"y\":0.5"),hostTime:0.02,now:0.02,send:sink)
    _ = session.receiveRemote(.tablet,token:t,bytes:wire("drumPads",4,2,",\"mask\":1"),hostTime:0.02,now:0.02,send:sink)
    _ = session.receive(.gamepad1,token:g,frame:down,now:0.02,send:sink)
    #expect(Set(events.filter { $0.command.value > 0 }.map(\.groupID)) == [phone.id,tablet.id,local.id])
    events.removeAll()
    _ = session.receive(.gamepad1,token:g,frame:down,now:0.2,send:sink)
    _ = session.receiveRemote(.tablet,token:t,bytes:wire("drumPads",4,3,",\"mask\":1"),hostTime:0.2,now:0.2,send:sink)
    _ = session.expire(now:0.38,send:sink)
    #expect(events.count == 1 && events[0].groupID == phone.id && events[0].command.value == 0)
    #expect(!session.boundSources.contains(.phone) && session.boundSources.contains(.tablet))
    events.removeAll()
    let old = session.receiveRemote(.phone,token:p,bytes:wire("release",1,4),hostTime:0.39,now:0.39,send:sink)
    #expect(old.status == .ignored && events.isEmpty)
    _ = session.panic(send:sink)
    #expect(Set(events.map(\.groupID)) == [tablet.id,local.id])
}

@Test func groupRemotePianoAndPedalSnapshotsAreStrictAndReleaseScoped() throws {
    let piano = remoteGroup(.phone,.pianoKey0,.init(.note,number:60))
    let pedal = remoteGroup(.tablet,.pedalSustain,.init(.sustain))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[piano,pedal]),allowRemote:true)
    let p = try session.bind(.phone,now:1)
    let t = try session.bind(.tablet,now:1)
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    _ = session.receiveRemote(.phone,token:p,bytes:wire("pianoKeys",5,1,",\"mask\":0"),hostTime:1,now:1,send:sink)
    _ = session.receiveRemote(.tablet,token:t,bytes:wire("pedalboard",6,1,",\"mask\":0,\"levels\":[0,0,0,0,0,0]"),hostTime:1,now:1,send:sink)
    _ = session.receiveRemote(.phone,token:p,bytes:wire("pianoKeys",5,2,",\"mask\":1"),hostTime:1.01,now:1.01,send:sink)
    _ = session.receiveRemote(.tablet,token:t,bytes:wire("pedalboard",6,2,",\"mask\":8,\"levels\":[0,0,0,1,0,0]"),hostTime:1.01,now:1.01,send:sink)
    #expect(events.count == 2)
    events.removeAll()
    let invalid = session.receiveRemote(.phone,token:p,bytes:wire("pianoKeys",5,3,",\"mask\":2"),hostTime:1.02,now:1.02,send:sink)
    #expect(invalid.status == .lost && events.count == 1 && events[0].groupID == piano.id)
    events.removeAll()
    let heartbeat = session.receiveRemote(.tablet,token:t,bytes:wire("heartbeat",1,3),hostTime:1.03,now:1.03,send:sink)
    #expect(heartbeat.status == .lost && events.count == 1 && events[0].groupID == pedal.id)
    #expect(session.boundSources.isEmpty)
}

@Test func groupRemoteRejectsOldSequenceAndPreBindingReceipt() throws {
    let phone = remoteGroup(.phone,.contact,.init(.note,number:60))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[phone]),allowRemote:true)
    let old = try session.bind(.phone,now:2)
    let early = session.receiveRemote(.phone,token:old,bytes:wire("release",1,1),hostTime:1.99,now:2,send:{ _ in true })
    #expect(early.status == .lost)
    let token = try session.bind(.phone,now:2.01)
    _ = session.receiveRemote(.phone,token:token,bytes:wire("release",1,1),hostTime:2.01,now:2.01,send:{ _ in true })
    let duplicate = session.receiveRemote(.phone,token:token,bytes:wire("touch",1,1,",\"x\":0.5,\"y\":0.5"),hostTime:2.02,now:2.02,send:{ _ in true })
    #expect(duplicate.status == .lost && session.boundSources.isEmpty)
}


@Test func groupRemoteActivationRequiresExplicitTransportAndMatchingProfile() throws {
    let phone = remoteGroup(.phone,.contact,.init(.note,number:60))
    let local = remoteGroup(.gamepad1,.padA,.init(.note,number:64))
    let mixed = PerformanceGroupProfile(groups:[phone,local])
    #expect(throws:PerformanceGroupActivationPlan.AdmissionError.remoteModeMismatch) {
        try PerformanceGroupActivationPlan(profile:mixed,mode:.standard,allowLayering:false,
            confirmedTuning:false,registeredIDs:[],cleanupIDs:[],pendingDisposalCount:0)
    }
    #expect(throws:PerformanceGroupActivationPlan.AdmissionError.remoteModeMismatch) {
        try PerformanceGroupActivationPlan(profile:.init(groups:[local]),mode:.standard,allowLayering:false,
            confirmedTuning:false,registeredIDs:[],cleanupIDs:[],pendingDisposalCount:0,allowRemote:true)
    }
    let accepted = try PerformanceGroupActivationPlan(profile:mixed,mode:.standard,allowLayering:false,
        confirmedTuning:false,registeredIDs:[],cleanupIDs:[],pendingDisposalCount:0,allowRemote:true)
    #expect(accepted.allowRemote)
    #expect(accepted.profile == mixed)
    #expect(throws:PerformanceGroupActivationPlan.AdmissionError.cleanupRequired) {
        try PerformanceGroupActivationPlan(profile:mixed,mode:.standard,allowLayering:false,
            confirmedTuning:false,registeredIDs:[],cleanupIDs:[phone.id],pendingDisposalCount:0,allowRemote:true)
    }
}


@Test func groupRemoteTwoFamiliesArmTogetherAndReleaseIndependently() throws {
    let group = PerformanceInstrumentGroup(name:"XY and drums",patch:.init(routes:[
        .init(id:"touch",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"drum",source:.phone,signal:.drumPad1,destination:.init(.note,channel:9,number:36))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
    let token = try session.bind(.phone,now:0)
    let capabilities = try #require(session.remoteCapabilities(.phone))
    #expect(capabilities.touch && capabilities.drums == 1 && capabilities.piano == 0)
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    let first = session.receiveRemote(.phone,token:token,bytes:wire("release",1,1),hostTime:0.01,now:0.01,send:sink)
    #expect(first.status == .waitingForNeutral)
    let held = session.receiveRemote(.phone,token:token,bytes:wire("drumPads",4,2,",\"mask\":1"),hostTime:0.02,now:0.02,send:sink)
    #expect(held.status == .waitingForNeutral && events.isEmpty)
    let ready = session.receiveRemote(.phone,token:token,bytes:wire("drumPads",4,3,",\"mask\":0"),hostTime:0.03,now:0.03,send:sink)
    #expect(ready.status == .ready)
    _ = session.receiveRemote(.phone,token:token,bytes:wire("touch",1,4,",\"x\":0.5,\"y\":0.5"),hostTime:0.04,now:0.04,send:sink)
    _ = session.receiveRemote(.phone,token:token,bytes:wire("drumPads",4,5,",\"mask\":1"),hostTime:0.05,now:0.05,send:sink)
    #expect(events.map(\.command.destination.number) == [60,36])
    #expect(events.allSatisfy { $0.command.value > 0 })
    events.removeAll()
    _ = session.receiveRemote(.phone,token:token,bytes:wire("release",1,6),hostTime:0.06,now:0.06,send:sink)
    #expect(events.count == 1 && events.first?.command.destination.number == 60 && events.first?.command.value == 0)
    #expect(session.activeSessions == 1)
    events.removeAll()
    _ = session.receiveRemote(.phone,token:token,bytes:wire("drumPads",4,7,",\"mask\":0"),hostTime:0.07,now:0.07,send:sink)
    #expect(events.count == 1 && events.first?.command.destination.number == 36 && events.first?.command.value == 0)
    #expect(session.activeSessions == 0 && session.sourceStates[.phone] == .armed)
}

@Test func groupRemoteTwoFamiliesCannotRenewEachOthersDeadline() throws {
    let group = PerformanceInstrumentGroup(name:"XY and pedals",patch:.init(routes:[
        .init(id:"touch",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"pedal",source:.phone,signal:.pedalSustain,destination:.init(.sustain))
    ]))
    let local = remoteGroup(.gamepad1,.padA,.init(.note,number:64))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group,local]),allowRemote:true)
    let phone = try session.bind(.phone,now:0)
    let controller = try session.bind(.gamepad1,now:0)
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12); buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    _ = session.receiveRemote(.phone,token:phone,bytes:wire("release",1,1),hostTime:0.01,now:0.01,send:sink)
    _ = session.receiveRemote(.phone,token:phone,bytes:wire("pedalboard",6,2,",\"mask\":0,\"levels\":[0,0,0,0,0,0]"),hostTime:0.02,now:0.02,send:sink)
    _ = session.receive(.gamepad1,token:controller,frame:neutral,now:0.02,send:sink)
    _ = session.receiveRemote(.phone,token:phone,bytes:wire("touch",1,3,",\"x\":0.5,\"y\":0.5"),hostTime:0.03,now:0.03,send:sink)
    _ = session.receiveRemote(.phone,token:phone,bytes:wire("pedalboard",6,4,",\"mask\":8,\"levels\":[0,0,0,1,0,0]"),hostTime:0.04,now:0.04,send:sink)
    _ = session.receive(.gamepad1,token:controller,frame:down,now:0.05,send:sink)
    _ = session.receiveRemote(.phone,token:phone,bytes:wire("pedalboard",6,5,",\"mask\":8,\"levels\":[0,0,0,1,0,0]"),hostTime:0.25,now:0.25,send:sink)
    _ = session.receive(.gamepad1,token:controller,frame:down,now:0.25,send:sink)
    events.removeAll()
    _ = session.expire(now:0.39,send:sink)
    #expect(events.count == 2 && events.allSatisfy { $0.groupID == group.id && $0.command.value == 0 })
    #expect(session.boundSources == [.gamepad1])
    #expect(session.activeSessions == 1)
    let stale = session.receiveRemote(.phone,token:phone,bytes:wire("release",1,6),hostTime:0.40,now:0.40,send:sink)
    #expect(stale.status == .ignored)
}


@Test func groupRemoteFourAssignedFamiliesRequireNeutralAndKeepTwoActiveLimit() throws {
    let group = PerformanceInstrumentGroup(name:"Switchable",patch:.init(routes:[
        .init(id:"xy",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"drum",source:.phone,signal:.drumPad1,destination:.init(.note,channel:9,number:36)),
        .init(id:"piano",source:.phone,signal:.pianoKey0,destination:.init(.note,number:64)),
        .init(id:"pedal",source:.phone,signal:.pedalSustain,destination:.init(.sustain))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
    let token = try session.bind(.phone,now:1)
    let caps = try #require(session.remoteCapabilities(.phone))
    #expect(caps.touch && caps.drums == 1 && caps.piano == 1 && caps.pedals == 8)
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    let neutral:[Data] = [wire("release",1,1),wire("drumPads",4,2,",\"mask\":0"),
                          wire("pianoKeys",5,3,",\"mask\":0"),
                          wire("pedalboard",6,4,",\"mask\":0,\"levels\":[0,0,0,0,0,0]")]
    for (i,frame) in neutral.enumerated() {
        let time=1+Double(i+1)*0.01
        let result=session.receiveRemote(.phone,token:token,bytes:frame,hostTime:time,now:time,send:sink)
        #expect(result.status == (i == 3 ? .ready : .waitingForNeutral))
    }
    #expect(events.isEmpty)
    let frames:[Data] = [
        wire("touch",1,5,",\"x\":0.5,\"y\":0.5"), wire("release",1,6),
        wire("pianoKeys",5,7,",\"mask\":1"), wire("pianoKeys",5,8,",\"mask\":0"),
        wire("drumPads",4,9,",\"mask\":1"), wire("drumPads",4,10,",\"mask\":0"),
        wire("pedalboard",6,11,",\"mask\":8,\"levels\":[0,0,0,1,0,0]"),
        wire("pedalboard",6,12,",\"mask\":0,\"levels\":[0,0,0,0,0,0]")]
    for (i,frame) in frames.enumerated() {
        let time=1.05+Double(i)*0.01
        let result=session.receiveRemote(.phone,token:token,bytes:frame,hostTime:time,now:time,send:sink)
        #expect(result.status == .ready || result.status == .delivered)
    }
    #expect(events.count == 8 && events.filter { $0.command.value == 0 }.count == 4)
    #expect(session.activeSessions == 0 && session.sourceStates[.phone] == .armed)
    events.removeAll()
    _ = session.receiveRemote(.phone,token:token,bytes:wire("touch",1,13,",\"x\":0.5,\"y\":0.5"),hostTime:1.2,now:1.2,send:sink)
    _ = session.receiveRemote(.phone,token:token,bytes:wire("drumPads",4,14,",\"mask\":1"),hostTime:1.21,now:1.21,send:sink)
    let third=session.receiveRemote(.phone,token:token,bytes:wire("pianoKeys",5,15,",\"mask\":1"),hostTime:1.22,now:1.22,send:sink)
    #expect(third.status == .lost && session.boundSources.isEmpty && session.activeSessions == 0)
    #expect(events.count == 4 && !events.contains { $0.command.destination.number == 64 })
}
