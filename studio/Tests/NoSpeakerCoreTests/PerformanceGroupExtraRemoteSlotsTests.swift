import Foundation
import Testing
@testable import NoSpeakerCore

private func extraSlotGroup(_ source:SensorSource,number:Int) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:[
        .init(id:"note",source:source,signal:.contact,destination:.init(.note,number:number))
    ],performanceLayout:.init(widgets:[.init(source:source,signal:.contact,kind:.key,label:"Custom key")])))
}

@Test func groupRemoteSlotRetargetPreservesIdentityAndOldArchives() throws {
    let original = extraSlotGroup(.phone,number:60)
    let other = extraSlotGroup(.tablet,number:64)
    var profile = PerformanceGroupProfile(groups:[original,other])
    let old = try profile.archive()
    #expect(try PerformanceGroupProfile.read(old) == profile)
    let rejected = profile.reassignRemoteSource(groupID:original.id,from:.phone,to:.tablet)
    #expect(!rejected && profile.groups[0] == original)
    let moved = profile.reassignRemoteSource(groupID:original.id,from:.phone,to:.phone2)
    #expect(moved)
    #expect(profile.groups[0].id == original.id && profile.groups[0].plannedPortName == original.plannedPortName)
    #expect(profile.groups[0].patch.routes[0].id == original.patch.routes[0].id)
    #expect(profile.groups[0].patch.routes[0].destination == original.patch.routes[0].destination)
    #expect(profile.groups[0].patch.routes[0].source == .phone2)
    #expect(profile.groups[0].patch.performanceLayout?.widgets[0].source == .phone2)
    #expect(profile.groups[0].patch.performanceLayout?.widgets[0].label == "Custom key")
    #expect(profile.groups[1] == other)
    let roundTrip = try PerformanceGroupProfile.read(profile.archive())
    #expect(roundTrip == profile)
    #expect(!SensorSource.legacyBuilderSources.contains(.phone2) && !SensorSource.legacyBuilderSources.contains(.tablet2))
    #expect(!PhysicalPatchRuntime.supports(profile.groups[0].patch,allowRemote:true))
}

@Test func groupRemoteExtraSlotsRequireExplicitPairingGate() throws {
    let secret = Data(repeating:11,count:32)
    var legacy = RemotePairingGate()
    #expect(throws:RemoteTouchError.invalidPairing) {
        try legacy.issue(secret:secret,source:.phone2,now:1)
    }
    try legacy.issue(secret:secret,source:.phone,now:1)
    let source = try legacy.consume(secret:secret,now:1.01)
    #expect(source == .phone)
    var group = RemotePairingGate()
    try group.issue(secret:secret,source:.tablet2,now:1,allowGroupSlots:true)
    let extra = try group.consume(secret:secret,now:1.01)
    #expect(extra == .tablet2)
}

@Test func groupFourRemotePeersRetainIndependentPortsAndLocalOwner() throws {
    let groups = SensorSource.groupRemoteSources.enumerated().map { index,source in
        extraSlotGroup(source,number:60+index)
    }
    let local = PerformanceInstrumentGroup(name:"Xbox",patch:.init(routes:[
        .init(id:"local",source:.gamepad1,signal:.padA,destination:.init(.note,number:70))
    ]))
    let profile = PerformanceGroupProfile(groups:groups+[local])
    #expect(PerformanceGroupGamepadSession.supports(profile,allowRemote:true))
    #expect(!PerformanceGroupGamepadSession.supports(profile))
    var session = try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    let localToken = try session.bind(.gamepad1,now:1)
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12);buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    _ = session.receive(.gamepad1,token:localToken,frame:neutral,now:1,send:sink)
    var peers:[UUID] = []
    for (i,source) in SensorSource.groupRemoteSources.enumerated() {
        let peer = UUID(), secret = Data(repeating:UInt8(i+1),count:32)
        peers.append(peer)
        let time = 1+Double(i)*0.02
        try bridge.issue(secret:secret,source:source,now:time,session:session)
        let accepted = bridge.process([.invitation(peer,secret,time+0.001)],now:time+0.001,session:&session,send:sink)
        #expect(accepted.actions == [.acknowledge(peer,true)])
        let release = Data("{\"version\":1,\"sequence\":1,\"kind\":\"release\"}".utf8)
        _ = bridge.process([.frame(peer,release,time+0.002)],now:time+0.002,session:&session,send:sink)
    }
    #expect(bridge.connectionIDs.count == 4 && session.boundSources.count == 5)
    let touch = Data("{\"version\":1,\"sequence\":2,\"kind\":\"touch\",\"x\":0.5,\"y\":0.5}".utf8)
    _ = bridge.process(peers.map { .frame($0,touch,1.1) },now:1.1,session:&session,send:sink)
    _ = session.receive(.gamepad1,token:localToken,frame:down,now:1.1,send:sink)
    #expect(Set(events.filter{$0.command.value > 0}.map(\.groupID)) == Set((groups+[local]).map(\.id)))
    events.removeAll()
    _ = bridge.revoke(peers[2],session:&session,send:sink)
    #expect(events.count == 1 && events.first?.groupID == groups[2].id && events.first?.command.value == 0)
    #expect(bridge.connectionIDs.count == 3 && !session.boundSources.contains(.phone2))
    events.removeAll()
    _ = bridge.stop(session:&session,send:sink)
    #expect(Set(events.map(\.groupID)) == Set([groups[0].id,groups[1].id,groups[3].id]))
    #expect(session.boundSources == [.gamepad1] && !session.retired)
}
