import Foundation
import Testing
@testable import NoSpeakerCore

private func wire(_ kind:String,_ version:Int,_ sequence:Int,_ extra:String = "") -> Data {
    Data("{\"kind\":\"\(kind)\",\"version\":\(version),\"sequence\":\(sequence)\(extra)}".utf8)
}

private func remoteGroup(_ source:SensorSource,_ signal:SensorSignal,_ target:SensorDestination) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[.init(id:"remote",source:source,signal:signal,destination:target)]))
}

@Test func groupRemoteOptInRejectsMixedModesAndUnsafeGain() throws {
    var a = remoteGroup(.phone,.contact,.init(.note,number:60))
    let profile = PerformanceGroupProfile(groups:[a])
    #expect(!PerformanceGroupGamepadSession.supports(profile))
    #expect(PerformanceGroupGamepadSession.supports(profile,allowRemote:true))
    a.patch.routes.append(.init(id:"drum",source:.phone,signal:.drumPad1,destination:.init(.note,number:36)))
    #expect(!PerformanceGroupGamepadSession.supports(.init(groups:[a]),allowRemote:true))
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
