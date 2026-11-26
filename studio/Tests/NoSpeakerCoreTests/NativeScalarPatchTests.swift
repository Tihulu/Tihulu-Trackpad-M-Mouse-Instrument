import Testing
@testable import NoSpeakerCore

@Test func nativeScalarAdaptersShareRouterAndReleaseIndependently() throws {
    let pedal = SensorDestination(.controlChange, number: 4)
    let bend = SensorDestination(.pitchBend)
    let patch = InstrumentPatch(routes: [
        .init(id: "lid", source: .lid, signal: .angle, destination: pedal, response: .init(release: 0.5)),
        .init(id: "bar", source: .touchBar, signal: .x, destination: bend)
    ])
    #expect(PhysicalPatchRuntime.supports(patch))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let lid = runtime.receiveScalar(source: .lid, value: 1, hostTime: 1, now: 1)
    let bar = runtime.receiveScalar(source: .touchBar, value: 0, hostTime: 1.1, now: 1.1)
    #expect(lid == [.init(pedal, value: 127)])
    #expect(bar == [.init(bend, value: 0)])
    let release = runtime.receiveScalar(source: .touchBar, value: nil, hostTime: 1.2, now: 1.2)
    #expect(release == [.init(bend, value: 8192)])
    #expect(runtime.activeSources == [.lid])
    #expect(runtime.expire(now: 1.5) == [.init(pedal, value: 64)])
}

@Test func lidNormalizationAndScalarCapabilityValidation() throws {
    #expect(PhysicalPatchRuntime.normalizedLid(5) == 0)
    #expect(PhysicalPatchRuntime.normalizedLid(90) == 0.5)
    #expect(PhysicalPatchRuntime.normalizedLid(175) == 1)
    #expect(PhysicalPatchRuntime.normalizedLid(.nan) == nil)
    #expect(PhysicalPatchRuntime.normalizedLid(180) == nil)
    let patch = InstrumentPatch(routes: [.init(id: "bad", source: .lid, signal: .speed, destination: .init(.pitchBend))])
    #expect(!PhysicalPatchRuntime.supports(patch))
}

@Test func staleScalarCannotRearmAfterStop() throws {
    var runtime = PhysicalPatchRuntime()
    let patch = InstrumentPatch(routes: [.init(id: "bar", source: .touchBar, signal: .x, destination: .init(.note, number: 60))])
    try runtime.configure(patch)
    #expect(runtime.receiveScalar(source: .touchBar, value: 1, hostTime: 1, now: 2).isEmpty)
    #expect(runtime.receiveScalar(source: .touchBar, value: 1, hostTime: 2, now: 2).count == 1)
    #expect(runtime.stop().count == 1)
    #expect(runtime.receiveScalar(source: .touchBar, value: 1, hostTime: 3, now: 3).isEmpty)
}


@Test func physicalScalarFreshSnapshotReleasesExpiredSharedOwnersAtomically() throws {
    let target=SensorDestination(.controlChange,number:74)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"high",source:.lid,signal:.angle,destination:target,priority:10),
        .init(id:"low",source:.touchBar,signal:.x,destination:target,priority:0)
    ]))
    #expect(runtime.receiveScalar(source:.lid,value:0.8,hostTime:1,now:1).count==1)
    _=runtime.receiveScalar(source:.touchBar,value:0.3,hostTime:1.01,now:1.01)
    let expired=runtime.receiveScalar(source:.lid,value:0.9,hostTime:1.37,now:1.37)
    #expect(expired==[.init(target,value:0)] && runtime.activeSources.isEmpty)
    #expect(runtime.receiveScalar(source:.lid,value:0.9,hostTime:1.36,now:1.38).isEmpty)
    #expect(runtime.receiveScalar(source:.lid,value:0.9,hostTime:1.39,now:1.39).count==1)
}
