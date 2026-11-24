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
