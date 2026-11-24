import Testing
@testable import NoSpeakerCore

@Test func physicalPatchReleasesLiftAndWatchdogWithoutDroppingOtherSource() throws {
    let note = SensorDestination(.note, number: 60)
    let patch = InstrumentPatch(routes: [
        .init(id: "a", source: .trackpad, signal: .contact, destination: note),
        .init(id: "b", source: .magicMouse, signal: .contact, destination: note)
    ])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let a = runtime.receive(source: .trackpad, x: 0.2, y: 0.3, size: 0.4, hostTime: 1, now: 1)
    #expect(a == [.init(note, value: 100)])
    let b = runtime.receive(source: .magicMouse, x: 0.5, y: 0.3, size: 0.4, hostTime: 1.1, now: 1.1)
    #expect(b.isEmpty)
    let lift = runtime.receive(source: .trackpad, x: nil, y: nil, size: nil, hostTime: 1.2, now: 1.2)
    #expect(lift.isEmpty)
    #expect(runtime.activeSources == [.magicMouse])
    let expired = runtime.expire(now: 1.5)
    #expect(expired == [.init(note, value: 0)])
    #expect(runtime.activeSources.isEmpty)
}

@Test func physicalPatchRejectsFakePressureAndStaleFrames() throws {
    var patch = InstrumentPatch.starter
    patch.routes[0].signal = .pressure
    #expect(!PhysicalPatchRuntime.supports(patch))
    patch = .starter
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let stale = runtime.receive(source: .trackpad, x: 0.2, y: 0.3, size: 0.4, hostTime: 1, now: 2)
    #expect(stale.isEmpty && runtime.activeSources.isEmpty)
    let fresh = runtime.receive(source: .trackpad, x: 0.25, y: 0.3, size: 0.4, hostTime: 2, now: 2)
    #expect(fresh.contains { $0.destination.kind == .note && $0.value == 100 })
    let stopped = runtime.stop()
    #expect(stopped.contains { $0.destination.kind == .note && $0.value == 0 })
    let after = runtime.receive(source: .trackpad, x: 0.3, y: 0.3, size: 0.4, hostTime: 3, now: 3)
    #expect(after.isEmpty)
}
