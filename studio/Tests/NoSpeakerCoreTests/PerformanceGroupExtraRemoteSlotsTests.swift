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


/// Synthetic serial-host workload, not a native socket/latency benchmark.
@Test func groupFourMixedSurfacePeersRefreshWithoutRetriggerAndRetireOnlyStalledPeer() throws {
    let groups = SensorSource.groupRemoteSources.enumerated().map { index,source in
        PerformanceInstrumentGroup(name:source.rawValue,patch:.init(routes:[
            .init(id:"touch",source:source,signal:.contact,destination:.init(.note,number:60+index)),
            .init(id:"drum",source:source,signal:.drumPad1,destination:.init(.note,channel:9,number:36))
        ]))
    }
    let local = PerformanceInstrumentGroup(name:"Xbox",patch:.init(routes:[
        .init(id:"local",source:.gamepad1,signal:.padA,destination:.init(.note,number:70))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:groups+[local]),allowRemote:true)
    var bridge = PerformanceGroupRemoteBridge()
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0); return true }
    func xy(_ sequence:Int,active:Bool) -> Data {
        let payload = active ? "\"kind\":\"touch\",\"x\":0.5,\"y\":0.5" : "\"kind\":\"release\""
        return Data("{\"version\":1,\"sequence\":\(sequence),\(payload)}".utf8)
    }
    func drum(_ sequence:Int,active:Bool) -> Data {
        Data("{\"version\":4,\"sequence\":\(sequence),\"kind\":\"drumPads\",\"mask\":\(active ? 1 : 0)}".utf8)
    }
    _ = bridge.process([.ready],now:1,session:&session,send:sink)
    let token = try session.bind(.gamepad1,now:1)
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12);buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    _ = session.receive(.gamepad1,token:token,frame:neutral,now:1,send:sink)
    var peers:[UUID] = []
    var sequence:[UUID:Int] = [:]
    for (index,source) in SensorSource.groupRemoteSources.enumerated() {
        let peer = UUID(),secret = Data(repeating:UInt8(index+1),count:32)
        let time = 1+Double(index)*0.02
        peers.append(peer);sequence[peer] = 2
        try bridge.issue(secret:secret,source:source,now:time,session:session)
        _ = bridge.process([.invitation(peer,secret,time+0.001)],now:time+0.001,session:&session,send:sink)
        _ = bridge.process([.frame(peer,xy(1,active:false),time+0.002),
                            .frame(peer,drum(2,active:false),time+0.002)],now:time+0.002,session:&session,send:sink)
    }
    #expect(bridge.connectionIDs.count == 4)
    let victim = peers[0]
    for tick in 0...80 {
        let now = 1.1+Double(tick)*0.05
        var frames:[RemoteHostEvent] = []
        for peer in peers {
            sequence[peer,default:0] += 1
            frames.append(.frame(peer,xy(sequence[peer]!,active:true),now))
            sequence[peer,default:0] += 1
            frames.append(.frame(peer,drum(sequence[peer]!,active:true),now))
        }
        let result = bridge.process(frames,now:now,session:&session,send:sink)
        #expect(!result.fault && result.actions.count == 8)
        #expect(result.actions.allSatisfy { if case .acknowledge(_,true) = $0 { return true }; return false })
        _ = session.receive(.gamepad1,token:token,frame:down,now:now,send:sink)
    }
    #expect(sent.count == 9 && sent.allSatisfy { $0.command.destination.kind == .note && $0.command.value > 0 })
    #expect(session.activeSessions == 5)
    sent.removeAll()
    for tick in 1...8 {
        let now = 5.1+Double(tick)*0.05
        var frames:[RemoteHostEvent] = []
        for peer in peers where bridge.connectionIDs.contains(peer) {
            // Keep the victim's drum lane live; intentionally stop XY alone.
            if peer != victim {
                sequence[peer,default:0] += 1
                frames.append(.frame(peer,xy(sequence[peer]!,active:true),now))
            }
            sequence[peer,default:0] += 1
            frames.append(.frame(peer,drum(sequence[peer]!,active:true),now))
        }
        _ = bridge.process(frames,now:now,session:&session,send:sink)
        _ = session.receive(.gamepad1,token:token,frame:down,now:now,send:sink)
    }
    #expect(!bridge.connectionIDs.contains(victim) && bridge.connectionIDs.count == 3)
    #expect(sent.count == 2 && sent.allSatisfy { $0.groupID == groups[0].id && $0.command.value == 0 })
    #expect(session.activeSessions == 4 && session.boundSources.contains(.gamepad1))
    sent.removeAll()
    _ = bridge.stop(session:&session,send:sink)
    #expect(sent.count == 6 && sent.allSatisfy { $0.command.value == 0 && $0.groupID != local.id })
    #expect(session.activeSessions == 1 && !session.retired)
}

@Test func groupTwoFamiliesShareSingleNinetyFrameReceiptBudget() throws {
    let group = PerformanceInstrumentGroup(name:"Mixed rate budget",patch:.init(routes:[
        .init(id:"touch",source:.phone2,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"drum",source:.phone2,signal:.drumPad1,destination:.init(.note,channel:9,number:36))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowRemote:true)
    let token = try session.bind(.phone2,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0); return true }
    for sequence in 1...91 {
        let now = 1+Double(sequence)*0.005
        let payload:String
        if sequence == 1 { payload = "\"version\":1,\"kind\":\"release\"" }
        else if sequence == 2 { payload = "\"version\":4,\"kind\":\"drumPads\",\"mask\":0" }
        else if sequence%2 == 1 { payload = "\"version\":1,\"kind\":\"touch\",\"x\":0.5,\"y\":0.5" }
        else { payload = "\"version\":4,\"kind\":\"drumPads\",\"mask\":1" }
        let bytes = Data("{\"sequence\":\(sequence),\(payload)}".utf8)
        let result = session.receiveRemote(.phone2,token:token,bytes:bytes,hostTime:now,now:now,send:sink)
        if sequence == 91 { #expect(result.status == .lost) }
        else { #expect(result.status != .lost && result.status != .admissionRejected) }
    }
    #expect(sent.count == 4 && sent.filter { $0.command.value == 0 }.count == 2)
    #expect(session.boundSources.isEmpty && session.activeSessions == 0)
}
