import Foundation
import Testing
@testable import NoSpeakerCore

private func capacityRoutes(_ source: SensorSource, all: Bool) -> [SensorMapping] {
    let routes: [SensorMapping] = [
        .init(id:"\(source.rawValue)-touch",source:source,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"\(source.rawValue)-tilt",source:source,signal:.tiltPitch,destination:.init(.controlChange,number:74)),
        .init(id:"\(source.rawValue)-accel",source:source,signal:.accelerationMagnitude,destination:.init(.controlChange,number:75)),
        .init(id:"\(source.rawValue)-rotation",source:source,signal:.rotationMagnitude,destination:.init(.controlChange,number:76))
    ]
    if !all { return routes }
    return routes + Array(RemoteDrumPads.routes(source:source).prefix(1)) +
        Array(RemotePiano.routes(source:source).prefix(1)) + Array(RemotePedalboard.routes(source:source).prefix(1))
}
private func capacityPair(_ runtime: inout PhysicalPatchRuntime, _ source: SensorSource, _ now: Double) throws -> UUID {
    let key = Data(repeating:42,count:32)
    try runtime.issueRemotePairing(secret:key,source:source,now:now)
    return try runtime.admitRemote(secret:key,now:now)
}
@Test func remoteReservationsProtectLocalBudgetAndExistingPeers() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true) + capacityRoutes(.tablet,all:false) +
        [.init(id:"local",source:.trackpad,signal:.contact,destination:.init(.note,number:62))]),allowRemote:true)
    let phone = try capacityPair(&runtime,.phone,1)
    let tablet = try capacityPair(&runtime,.tablet,1.1)
    #expect(runtime.reservedRemoteSessions == 11)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.phone,1.2) }
    #expect(runtime.remotePeerIDs == [phone,tablet])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2) == [.init(.init(.note,number:62),value:100)])
    let release = Data(#"{"version":1,"sequence":1,"kind":"release"}"#.utf8)
    #expect(runtime.receiveRemote(phone,bytes:release,now:1.3) == .accepted([]))
    #expect(runtime.reservedRemoteSessions == 11)
    _ = runtime.revokeRemote(phone)
    #expect(runtime.reservedRemoteSessions == 4)
    _ = try capacityPair(&runtime,.phone,1.4)
    #expect(runtime.reservedRemoteSessions == 11)
    _ = runtime.disableRemote()
    #expect(runtime.reservedRemoteSessions == 0)
    #expect(runtime.activeSources.contains(.trackpad))
}
@Test func remoteReservationsRejectSecondFullPeerAndRecoverOnExpiry() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true)),allowRemote:true)
    let first = try capacityPair(&runtime,.phone,1)
    #expect(runtime.reservedRemoteSessions == 7)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.phone,1.1) }
    #expect(runtime.remotePeerIDs == [first])
    _ = runtime.expire(now:3.1)
    #expect(runtime.reservedRemoteSessions == 0)
    _ = try capacityPair(&runtime,.phone,3.2)
    #expect(runtime.reservedRemoteSessions == 7)
    _ = runtime.stop()
    #expect(runtime.reservedRemoteSessions == 0)
}


private func budgetFrame(_ sequence: Int, _ version: Int, _ kind: String, _ payload: String = "") -> Data {
    Data(("{\"version\":\(version),\"sequence\":\(sequence),\"kind\":\"\(kind)\"" + payload + "}").utf8)
}

@Test func remoteBudgetActuallyAllocatesAllSixteenSessionsAndPreservesSharedNote() throws {
    let note = SensorDestination(.note,number:60)
    let locals: [SensorMapping] = [
        .init(id:"local-trackpad",source:.trackpad,signal:.contact,destination:note),
        .init(id:"local-mouse",source:.magicMouse,signal:.contact,destination:note),
        .init(id:"local-lid",source:.lid,signal:.angle,destination:.init(.controlChange,number:20)),
        .init(id:"local-bar",source:.touchBar,signal:.x,destination:.init(.controlChange,number:21)),
        .init(id:"local-camera",source:.camera,signal:.contact,destination:note)
    ]
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true) + capacityRoutes(.tablet,all:false) + locals),allowRemote:true)
    let phone = try capacityPair(&runtime,.phone,1)
    let tablet = try capacityPair(&runtime,.tablet,1.01)
    #expect(runtime.reservedRemoteSessions == 11)
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.02,now:1.02) == [.init(note,value:100)])
    #expect(runtime.receive(source:.magicMouse,x:0.5,y:0.5,size:0.5,hostTime:1.02,now:1.02).isEmpty)
    _ = runtime.receiveScalar(source:.lid,value:0.5,hostTime:1.02,now:1.02)
    _ = runtime.receiveScalar(source:.touchBar,value:0.5,hostTime:1.02,now:1.02)
    let hand = try #require(AirHandSample(thumb:.init(x:0.2,y:0.4,confidence:1),
        index:.init(x:0.3,y:0.4,confidence:1),wrist:.init(x:0.3,y:0.1,confidence:1),
        middleBase:.init(x:0.3,y:0.3,confidence:1)))
    #expect(runtime.receiveHand(hand,hostTime:1.02,now:1.02).isEmpty)
    #expect(runtime.activeRouterSessionCount == 5)
    let touch = ",\"x\":0.5,\"y\":0.5"
    let tilt = ",\"alpha\":0,\"beta\":0,\"gamma\":0"
    let tilted = ",\"alpha\":0,\"beta\":20,\"gamma\":0"
    let accel = ",\"x\":10,\"y\":0,\"z\":0"
    let rotation = ",\"x\":180,\"y\":0,\"z\":0"
    let frames = [
        budgetFrame(1,1,"touch",touch),budgetFrame(2,2,"orientationArm",tilt),
        budgetFrame(3,2,"orientation",tilted),budgetFrame(4,3,"accelerationArm",accel),
        budgetFrame(5,3,"acceleration",accel),budgetFrame(6,3,"rotationArm",rotation),
        budgetFrame(7,3,"rotation",rotation)
    ]
    for (i,frame) in frames.enumerated() {
        let result = runtime.receiveRemote(phone,bytes:frame,now:1.03+Double(i)*0.01)
        if case .accepted = result {} else { Issue.record("Phone stream refused") }
    }
    for (i,frame) in [
        budgetFrame(8,4,"drumPads",",\"mask\":1"),
        budgetFrame(9,5,"pianoKeys",",\"mask\":1"),
        budgetFrame(10,6,"pedalboard",",\"mask\":1,\"levels\":[0.5,0,0,0,0,0]")
    ].enumerated() {
        if case .accepted = runtime.receiveRemote(phone,bytes:frame,now:1.10+Double(i)*0.01) {} else { Issue.record("Phone discrete stream refused") }
    }
    #expect(runtime.activeRouterSessionCount == 12)
    for (i,frame) in frames.enumerated() {
        if case .accepted = runtime.receiveRemote(tablet,bytes:frame,now:1.13+Double(i)*0.01) {} else { Issue.record("Tablet stream refused") }
    }
    #expect(runtime.activeRouterSessionCount == SensorRouter.maxSessions)
    #expect(runtime.activeSources.count == 5)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.tablet,1.21) }
    #expect(runtime.activeRouterSessionCount == 16 && runtime.remotePeerIDs == [phone,tablet])
    let revoked = runtime.revokeRemote(phone)
    #expect(!revoked.contains(.init(note,value:0)))
    #expect(runtime.activeRouterSessionCount == 9)
    #expect(runtime.revokeRemote(phone).isEmpty)
    #expect(!runtime.disableRemote().contains(.init(note,value:0)))
    #expect(runtime.activeRouterSessionCount == 5 && runtime.reservedRemoteSessions == 0)
    let expired = runtime.expire(now:1.5)
    #expect(expired.filter { $0 == .init(note,value:0) }.count == 1)
    #expect(runtime.activeRouterSessionCount == 0 && runtime.activeSources.isEmpty)
    #expect(runtime.stop().isEmpty)
}

@Test func remotePeerLimitConsumesValidRefusedInvitationWithoutEviction() throws {
    var runtime = PhysicalPatchRuntime()
    let note = SensorDestination(.note,number:60)
    try runtime.configure(.init(routes:[.init(id:"shared",source:.phone,signal:.contact,destination:note)]),allowRemote:true)
    var peers: [UUID] = []
    for i in 0..<4 {
        let id = try capacityPair(&runtime,.phone,1+Double(i)*0.01)
        peers.append(id)
        let result = runtime.receiveRemote(id,bytes:budgetFrame(1,1,"touch",",\"x\":0.5,\"y\":0.5"),now:1.05+Double(i)*0.01)
        #expect(result == .accepted(i == 0 ? [.init(note,value:100)] : []))
    }
    let key = Data(repeating:99,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1.1,mappingDetails:true)
    #expect(throws:RemoteTouchError.capacity) { try runtime.admitRemote(secret:key,now:1.11) }
    #expect(runtime.remotePeerIDs == Set(peers))
    #expect(runtime.activeRouterSessionCount == 4)
    #expect(runtime.revokeRemote(peers[0]).isEmpty)
    #expect(throws:RemoteTouchError.invalidPairing) { try runtime.admitRemote(secret:key,now:1.12) }
    let replacement = try capacityPair(&runtime,.phone,1.13)
    #expect(runtime.remotePeerIDs.count == 4)
    #expect(runtime.receiveRemote(replacement,bytes:budgetFrame(1,1,"touch",",\"x\":0.5,\"y\":0.5"),now:1.14) == .accepted([]))
    #expect(runtime.expire(now:1.6).filter { $0 == .init(note,value:0) }.count == 1)
    #expect(runtime.activeRouterSessionCount == 0 && runtime.remotePeerIDs.isEmpty)
    #expect(runtime.expire(now:1.7).isEmpty)
}


@Test func remoteRevocationNeverRestoresAnotherDepartingStream() throws {
    let target = SensorDestination(.controlChange,number:74)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"local",source:.trackpad,signal:.x,destination:target,priority:0),
        .init(id:"touch",source:.phone,signal:.x,destination:target,priority:20),
        .init(id:"motion",source:.phone,signal:.tiltPitch,destination:target,priority:10)
    ]),allowRemote:true)
    let peer = try capacityPair(&runtime,.phone,1)
    let local = runtime.receive(source:.trackpad,x:0.2,y:0.5,size:0.5,hostTime:1.01,now:1.01)
    #expect(local.count == 1)
    #expect(runtime.receiveRemote(peer,bytes:budgetFrame(1,1,"touch",",\"x\":0.9,\"y\":0.5"),now:1.02) == .accepted([.init(target,value:114)]))
    #expect(runtime.receiveRemote(peer,bytes:budgetFrame(2,2,"orientationArm",",\"alpha\":0,\"beta\":0,\"gamma\":0"),now:1.03) == .accepted([]))
    #expect(runtime.receiveRemote(peer,bytes:budgetFrame(3,2,"orientation",",\"alpha\":0,\"beta\":20,\"gamma\":0"),now:1.04) == .accepted([]))
    #expect(runtime.activeRouterSessionCount == 3)
    #expect(runtime.revokeRemote(peer) == local)
    #expect(runtime.activeRouterSessionCount == 1)
    #expect(runtime.revokeRemote(peer).isEmpty)
}

@Test func remoteDisableAndExpiryReconcileOnlySurvivingOwners() throws {
    let target = SensorDestination(.controlChange,number:74)
    let routes: [SensorMapping] = [
        .init(id:"local",source:.trackpad,signal:.x,destination:target,priority:0),
        .init(id:"phone",source:.phone,signal:.x,destination:target,priority:20),
        .init(id:"tablet",source:.tablet,signal:.x,destination:target,priority:10)
    ]
    for expire in [false,true] {
        var runtime = PhysicalPatchRuntime()
        try runtime.configure(.init(routes:routes),allowRemote:true)
        let phone = try capacityPair(&runtime,.phone,1)
        let tablet = try capacityPair(&runtime,.tablet,1.01)
        let local = runtime.receive(source:.trackpad,x:0.2,y:0.5,size:0.5,hostTime:1.02,now:1.02)
        _ = runtime.receiveRemote(tablet,bytes:budgetFrame(1,1,"touch",",\"x\":0.6,\"y\":0.5"),now:1.03)
        _ = runtime.receiveRemote(phone,bytes:budgetFrame(1,1,"touch",",\"x\":0.9,\"y\":0.5"),now:1.04)
        #expect(runtime.activeRouterSessionCount == 3)
        let actual = expire ? runtime.expire(now:1.5) : runtime.disableRemote()
        #expect(actual == (expire ? [.init(target,value:0)] : local))
        #expect(runtime.activeRouterSessionCount == (expire ? 0 : 1))
        #expect(runtime.remotePeerIDs.isEmpty)
    }
}

@Test func hybridRemoteFullBudgetAndSharedNoteIsolation() throws {
    let note = SensorDestination(.note,number:60)
    let locals:[SensorMapping] = [
        .init(id:"track",source:.trackpad,signal:.contact,destination:note),
        .init(id:"mouse",source:.magicMouse,signal:.contact,destination:note),
        .init(id:"synthetic",source:.external,signal:.contact,destination:note),
        .init(id:"bar",source:.touchBar,signal:.x,destination:.init(.controlChange,number:21)),
        .init(id:"camera",source:.camera,signal:.contact,destination:note)]
    let routes = locals + capacityRoutes(.phone,all:true) + capacityRoutes(.tablet,all:false)
    let patch = InstrumentPatch(routes:routes)
    #expect(PhysicalPatchRuntime.supportsHybrid(patch,synthetic:.external,allowRemote:true))
    #expect(!PhysicalPatchRuntime.supportsHybrid(patch,synthetic:.external))
    #expect(!PhysicalPatchRuntime.supportsHybrid(.init(routes:routes+[.init(id:"sixth",source:.lid,signal:.angle,destination:.init(.pitchBend))]),synthetic:.external,allowRemote:true))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true,synthetic:.external)
    let phone = try capacityPair(&runtime,.phone,1)
    let tablet = try capacityPair(&runtime,.tablet,1.01)
    #expect(runtime.reservedRemoteSessions == 11)
    let input = PatchSimulation.Input(source:.external,signal:.contact)
    #expect(runtime.sendHybrid(input,value:1,now:1.02) == [.init(note,value:100)])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.02,now:1.02).isEmpty)
    _ = runtime.receive(source:.magicMouse,x:0.5,y:0.5,size:0.5,hostTime:1.02,now:1.02)
    _ = runtime.receiveScalar(source:.touchBar,value:0.5,hostTime:1.02,now:1.02)
    _ = runtime.receiveHand(AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8),hostTime:1.02,now:1.02)
    #expect(runtime.activeRouterSessionCount == 5)
    let frames = [
        budgetFrame(1,1,"touch",",\"x\":0.5,\"y\":0.5"),
        budgetFrame(2,2,"orientationArm",",\"alpha\":0,\"beta\":0,\"gamma\":0"),
        budgetFrame(3,2,"orientation",",\"alpha\":0,\"beta\":20,\"gamma\":0"),
        budgetFrame(4,3,"accelerationArm",",\"x\":10,\"y\":0,\"z\":0"),
        budgetFrame(5,3,"acceleration",",\"x\":10,\"y\":0,\"z\":0"),
        budgetFrame(6,3,"rotationArm",",\"x\":180,\"y\":0,\"z\":0"),
        budgetFrame(7,3,"rotation",",\"x\":180,\"y\":0,\"z\":0")]
    for (i,frame) in frames.enumerated() {
        if case .accepted = runtime.receiveRemote(phone,bytes:frame,now:1.03+Double(i)*0.01) {} else { Issue.record("Phone stream refused") }
    }
    for (i,frame) in [
        budgetFrame(8,4,"drumPads",",\"mask\":1"),
        budgetFrame(9,5,"pianoKeys",",\"mask\":1"),
        budgetFrame(10,6,"pedalboard",",\"mask\":1,\"levels\":[0.5,0,0,0,0,0]")
    ].enumerated() {
        if case .accepted = runtime.receiveRemote(phone,bytes:frame,now:1.10+Double(i)*0.01) {} else { Issue.record("Discrete stream refused") }
    }
    for (i,frame) in frames.enumerated() {
        if case .accepted = runtime.receiveRemote(tablet,bytes:frame,now:1.13+Double(i)*0.01) {} else { Issue.record("Tablet stream refused") }
    }
    #expect(runtime.activeRouterSessionCount == 16)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.phone,1.21) }
    #expect(!runtime.releaseHybridSource().contains(.init(note,value:0)))
    #expect(runtime.activeRouterSessionCount == 15)
    #expect(runtime.sendHybrid(input,value:1,now:1.22).isEmpty)
    #expect(runtime.activeRouterSessionCount == 16)
    #expect(!runtime.disableRemote().contains(.init(note,value:0)))
    #expect(runtime.activeRouterSessionCount == 5)
    #expect(runtime.expire(now:1.6).filter { $0 == .init(note,value:0) }.count == 1)
    #expect(runtime.activeRouterSessionCount == 0)
}

@Test func gamepadSlotsReserveCapacityBeforeRemoteAdmission() throws {
    var runtime = PhysicalPatchRuntime()
    let controllers = [SensorSource.gamepad1,.gamepad2].map {
        SensorMapping(id:$0.rawValue,source:$0,signal:.padA,destination:.init(.note,number:60))
    }
    try runtime.configure(.init(routes:capacityRoutes(.phone,all:true)+capacityRoutes(.tablet,all:false)+controllers),allowRemote:true)
    #expect(runtime.reservedGamepadSessions == 2)
    #expect(runtime.remoteSessionLimit == 9)
    _ = try capacityPair(&runtime,.phone,1)
    #expect(throws:RemoteTouchError.capacity) { try capacityPair(&runtime,.tablet,1.1) }
    #expect(runtime.reservedRemoteSessions == 7)
}
