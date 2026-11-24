import Testing
@testable import NoSpeakerCore

@Test func wahPresetUsesCC4AndFirstNeutralAndScopedRelease() throws {
    let patch = try ExpressivePreset.wah.appending(to: .init(), source: .trackpad, signal: .x, channel: 2)
    #expect(PhysicalPatchRuntime.supports(patch))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let target = SensorDestination(.controlChange, channel: 2, number: 4)
    let heel = runtime.receive(source: .trackpad, x: 0, y: 0, size: 0.5, hostTime: 1, now: 1)
    #expect(heel == [.init(target, value: 0)])
    let toe = runtime.receive(source: .trackpad, x: 1, y: 0, size: 0.5, hostTime: 1.1, now: 1.1)
    #expect(toe == [.init(target, value: 127)])
    #expect(runtime.stop() == [.init(target, value: 0)])
}

@Test func expressivePresetAppendsWithoutMutatingOrReplacingOtherRoutes() throws {
    let original = InstrumentPatch.starter
    let patch = try ExpressivePreset.expression.appending(to: original, source: .magicMouse,
                                                           signal: .y, channel: 0, inverted: true)
    #expect(Array(patch.routes.prefix(original.routes.count)) == original.routes)
    #expect(patch.routes.last?.calibration.inverted == true)
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(throws: ExpressivePresetError.targetConflict) {
        try ExpressivePreset.expression.appending(to: patch, source: .trackpad, signal: .x, channel: 0)
    }
}

@Test func xyPresetRequiresTwoAxesAndProducesIndependentTargets() throws {
    let patch = try ExpressivePreset.xyFilter.appending(to: .init(), source: .trackpad, signal: .x, channel: 0)
    #expect(patch.routes.map(\.signal) == [.x,.y])
    #expect(patch.routes.map(\.destination.number) == [74,71])
    #expect(throws: ExpressivePresetError.unsupportedInput) {
        try ExpressivePreset.xyFilter.appending(to: .init(), source: .lid, signal: .angle, channel: 0)
    }
    let phone = try ExpressivePreset.whammy.appending(to: .init(), source: .phone, signal: .tiltRoll, channel: 0)
    #expect(!PhysicalPatchRuntime.supports(phone))
    #expect(PhysicalPatchRuntime.supports(phone,allowRemote:true))
    #expect(phone.routes.first?.destination.kind == .pitchBend)
}

@Test func firstContinuousNeutralIsSentOnlyWhenOwned() throws {
    var router = SensorRouter()
    let bend = SensorDestination(.pitchBend)
    try router.configure([.init(id: "bend", source: .lid, signal: .angle, destination: bend)])
    #expect(router.panic().isEmpty)
    let id = try router.connect(.lid, now: 1)
    let first = router.ingest(.init(session: id, signal: .angle, value: 0.5, sequence: 1, timestamp: 1), now: 1)
    #expect(first == [.init(bend, value: 8192)])
    let repeatSample = router.ingest(.init(session: id, signal: .angle, value: 0.5, sequence: 2, timestamp: 1.1), now: 1.1)
    #expect(repeatSample.isEmpty)
    #expect(router.disconnect(id).isEmpty)
}

@Test func allRemoteExpressiveSignalsHaveNativeTransport() throws {
    for source in [SensorSource.phone,.tablet] {
        for signal in ExpressivePreset.signals(for:source) {
            let patch = try ExpressivePreset.whammy.appending(to:.init(),source:source,signal:signal,channel:0)
            #expect(PhysicalPatchRuntime.supports(patch,allowRemote:true))
        }
        let patch = try ExpressivePreset.tiltEffects.appending(to:.init(),source:source,signal:.tiltRoll,channel:3)
        #expect(PhysicalPatchRuntime.supports(patch,allowRemote:true))
        #expect(patch.routes.map(\.signal) == [.tiltRoll,.tiltPitch,.tiltYaw])
        #expect(patch.routes.allSatisfy { $0.destination.channel == 3 && $0.response?.smoothingMS == 25 })
        #expect(try InstrumentPatch.read(patch.archive()) == patch)
    }
    #expect(throws:ExpressivePresetError.unsupportedInput) {
        try ExpressivePreset.whammy.appending(to:.init(),source:.phone,signal:.angle,channel:0)
    }
}
