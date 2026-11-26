import Testing
@testable import NoSpeakerCore

@Test func hybridSharedNoteOwnershipAndLease() throws {
    let patch = InstrumentPatch(routes:[
        .init(id:"native",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"synthetic",source:.lid,signal:.angle,destination:.init(.note,number:60))])
    #expect(PhysicalPatchRuntime.supportsHybrid(patch,synthetic:.lid))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,synthetic:.lid)
    let input = PatchSimulation.Input(source:.lid,signal:.angle)
    let note = SensorDestination(.note,number:60)
    #expect(runtime.receiveScalar(source:.lid,value:1,hostTime:1,now:1).isEmpty)
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1,now:1) == [.init(note,value:100)])
    #expect(runtime.sendHybrid(input,value:1,now:1.1).isEmpty)
    #expect(runtime.receive(source:.trackpad,x:nil,y:nil,size:nil,hostTime:1.2,now:1.2).isEmpty)
    #expect(runtime.refreshHybrid(now:1.3).isEmpty)
    #expect(runtime.expire(now:1.7) == [.init(note,value:0)])
    #expect(runtime.refreshHybrid(now:1.8).isEmpty)
    #expect(runtime.sendHybrid(input,value:1,now:1.9) == [.init(note,value:100)])
    #expect(runtime.releaseHybridSource() == [.init(note,value:0)])
}

@Test func hybridLeaseLossDoesNotReleaseNativeControls() throws {
    let patch = InstrumentPatch(routes:[
        .init(id:"native",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"synthetic",source:.external,signal:.x,destination:.init(.pitchBend))])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,synthetic:.external)
    let input = PatchSimulation.Input(source:.external,signal:.x)
    let note = SensorDestination(.note,number:60)
    let bend = SensorDestination(.pitchBend)
    #expect(runtime.sendHybrid(input,value:1,now:1) == [.init(bend,value:16383)])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2) == [.init(note,value:100)])
    #expect(runtime.refreshHybrid(now:1.4) == [.init(bend,value:8192)])
    #expect(runtime.activeSources == [.trackpad])
    #expect(runtime.sendHybrid(.init(source:.trackpad,signal:.contact),value:1,now:1.41).isEmpty)
    #expect(runtime.stop() == [.init(note,value:0)])
}

@Test func hybridRejectsRemoteCameraAndSyntheticOnly() throws {
    let native = SensorMapping(id:"native",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
    let remote = SensorMapping(id:"remote",source:.phone,signal:.x,destination:.init(.pitchBend))
    let camera = SensorMapping(id:"camera",source:.camera,signal:.x,destination:.init(.pitchBend))
    #expect(!PhysicalPatchRuntime.supportsHybrid(.init(routes:[native]),synthetic:.trackpad))
    #expect(!PhysicalPatchRuntime.supportsHybrid(.init(routes:[native,remote]),synthetic:.phone))
    #expect(!PhysicalPatchRuntime.supportsHybrid(.init(routes:[native,camera]),synthetic:.camera))
    let patch = InstrumentPatch(routes:[native,.init(id:"external",source:.external,signal:.x,destination:.init(.pitchBend))])
    var runtime = PhysicalPatchRuntime()
    #expect(throws:SensorRouterError.invalidMappings) { try runtime.configure(patch,allowRemote:true,synthetic:.external) }
}

@Test func hybridAtomicExpiryAndClockRegression() throws {
    let patch = InstrumentPatch(routes:[
        .init(id:"native",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"synthetic",source:.external,signal:.contact,destination:.init(.note,number:60))])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,synthetic:.external)
    let input = PatchSimulation.Input(source:.external,signal:.contact)
    let note = SensorDestination(.note,number:60)
    #expect(runtime.sendHybrid(input,value:1,now:1) == [.init(note,value:100)])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1,now:1).isEmpty)
    #expect(runtime.expire(now:1.4) == [.init(note,value:0)])
    #expect(runtime.refreshHybrid(now:1.5).isEmpty)
    #expect(runtime.sendHybrid(input,value:1,now:2) == [.init(note,value:100)])
    #expect(runtime.sendHybrid(input,value:1,now:1.9) == [.init(note,value:0)])
    #expect(runtime.refreshHybrid(now:2.1).isEmpty)
}

@Test func hybridSyntheticCameraUsesRealEngineAndRejectsNativeFrames() throws {
    let sustain = AirHandsHelper.route(hand:.left,axis:.pinch,effect:.sustain)!
    let patch = InstrumentPatch(routes:[sustain,.init(id:"native",source:.trackpad,signal:.contact,destination:.init(.note,number:60))])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,synthetic:.camera)
    #expect(runtime.hybridInputs.isEmpty)
    let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
    let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
    #expect(runtime.receiveHelperHands(left:open,right:nil,hostTime:1,now:1).isEmpty)
    #expect(runtime.activeRouterSessionCount == 0)
    _ = runtime.receiveHelperHands(left:open,right:nil,hostTime:1,now:1,synthetic:true)
    _ = runtime.receiveHelperHands(left:open,right:nil,hostTime:1.07,now:1.07,synthetic:true)
    #expect(runtime.receiveHelperHands(left:closed,right:nil,hostTime:1.14,now:1.14,synthetic:true) == [.init(.init(.sustain),value:127)])
    _ = runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2)
    #expect(runtime.refreshHybrid(now:1.3).isEmpty)
    #expect(runtime.expire(now:1.4) == [.init(.init(.sustain),value:0)])
    #expect(runtime.activeSources == [.trackpad])
    #expect(runtime.receiveHelperHands(left:closed,right:nil,hostTime:1.41,now:1.41,synthetic:true).isEmpty)
    #expect(runtime.releaseHybridSource().isEmpty)
    #expect(runtime.stop() == [.init(.init(.note,number:60),value:0)])
}


@Test func hybridDepartureAndExpiredPhysicalOwnerReconcileTogether() throws {
    for explicit in [false,true] {
        let cc=SensorDestination(.controlChange,number:74)
        var runtime=PhysicalPatchRuntime()
        try runtime.configure(.init(routes:[
            .init(id:"native",source:.trackpad,signal:.x,destination:cc,priority:0),
            .init(id:"synthetic",source:.external,signal:.x,destination:cc,priority:10)
        ]),synthetic:.external)
        let input=PatchSimulation.Input(source:.external,signal:.x)
        _=runtime.receive(source:.trackpad,x:0.3,y:0.5,size:0.5,hostTime:1,now:1)
        _=runtime.sendHybrid(input,value:0.8,now:explicit ? 1.2 : 1.01)
        let commands=explicit ? runtime.releaseHybridSource(now:1.37) : runtime.refreshHybrid(now:1.37)
        #expect(commands==[.init(cc,value:0)])
        #expect(runtime.activeSources.isEmpty && runtime.activeRouterSessionCount==0)
        #expect(runtime.refreshHybrid(now:1.38).isEmpty)
    }
}

@Test func hybridExplicitDepartureRetainsFreshPhysicalWinner() throws {
    let cc=SensorDestination(.controlChange,number:74)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"native",source:.trackpad,signal:.x,destination:cc,priority:0),
        .init(id:"synthetic",source:.external,signal:.x,destination:cc,priority:10)
    ]),synthetic:.external)
    _=runtime.receive(source:.trackpad,x:0.3,y:0.5,size:0.5,hostTime:1,now:1)
    _=runtime.sendHybrid(.init(source:.external,signal:.x),value:0.8,now:1.01)
    #expect(runtime.releaseHybridSource(now:1.1)==[.init(cc,value:38)])
    #expect(runtime.activeSources==[.trackpad])
}


@Test func hybridAxisReleaseBatchesExpiredOwnersAndRetainsSiblingAxis() throws {
    for hybridHigher in [false,true] {
        let cc=SensorDestination(.controlChange,number:74)
        let bend=SensorDestination(.pitchBend)
        var runtime=PhysicalPatchRuntime()
        try runtime.configure(.init(routes:[
            .init(id:"native",source:.trackpad,signal:.x,destination:cc,priority:hybridHigher ? 0 : 10),
            .init(id:"synthetic",source:.external,signal:.x,destination:cc,priority:hybridHigher ? 10 : 0),
            .init(id:"sibling",source:.external,signal:.y,destination:bend)
        ]),synthetic:.external)
        let x=PatchSimulation.Input(source:.external,signal:.x)
        let y=PatchSimulation.Input(source:.external,signal:.y)
        _=runtime.receive(source:.trackpad,x:0.3,y:0.5,size:0.5,hostTime:1,now:1)
        _=runtime.sendHybrid(x,value:0.8,now:1.2)
        _=runtime.sendHybrid(y,value:1,now:1.21)
        #expect(runtime.releaseHybrid(x,now:1.36)==[.init(cc,value:0)])
        #expect(runtime.activeSources.isEmpty && runtime.activeRouterSessionCount==1)
        #expect(runtime.releaseHybrid(y,now:1.37)==[.init(bend,value:8192)])
    }
}
