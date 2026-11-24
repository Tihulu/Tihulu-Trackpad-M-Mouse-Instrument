import Testing
@testable import NoSpeakerCore

private func airPose(aperture: Double, x: Double = 0.5, y: Double = 0.5) throws -> AirHandSample {
    let index = AirHandPoint(x: x, y: y, confidence: 0.9)
    let thumb = AirHandPoint(x: x - aperture * 0.3, y: y, confidence: 0.9)
    return try #require(AirHandSample(thumb: thumb, index: index,
        wrist: .init(x: 0.5,y: 0.2,confidence: 0.9),
        middleBase: .init(x: 0.5,y: 0.4,confidence: 0.9)))
}

@Test func airThereminPinchGateHysteresisAndLoss() throws {
    let patch = try AirInstrumentPreset.theremin.appending(to: .init(), channel: 2, note: 60)
    #expect(patch.routes.count == 3 && PhysicalPatchRuntime.supports(patch))
    let note = SensorDestination(.note, channel: 2, number: 60)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let open = try airPose(aperture: 0.7)
    let closed = try airPose(aperture: 0.1)
    let between = try airPose(aperture: 0.25)
    let initial = runtime.receiveHand(open, hostTime: 1, now: 1)
    #expect(!initial.contains { $0.destination == note })
    #expect(runtime.receiveHand(closed, hostTime: 1.1, now: 1.1).contains(.init(note, value: 100)))
    #expect(!runtime.receiveHand(between, hostTime: 1.2, now: 1.2).contains { $0.destination == note })
    #expect(runtime.receiveHand(open, hostTime: 1.3, now: 1.3).contains(.init(note, value: 0)))
    #expect(runtime.receiveHand(closed, hostTime: 1.4, now: 1.4).contains(.init(note, value: 100)))
    #expect(runtime.receiveHand(nil, hostTime: 1.5, now: 1.5).contains(.init(note, value: 0)))
}

@Test func airRangeCapturePreservesOtherSettingsAndRejectsShortRange() throws {
    let patch = try AirInstrumentPreset.theremin.appending(to: .init(), channel: 0)
    var capture = AirRangeCapture(signal: .gesture, first: 0.8, second: 0.1)
    let updated = try capture.applying(to: patch)
    #expect(updated.routes.prefix(2) == patch.routes.prefix(2))
    let gate = try #require(updated.routes.last)
    #expect(gate.calibration.minimum == 0.1 && gate.calibration.maximum == 0.8)
    #expect(gate.calibration.inverted && gate.threshold == 0.8)
    #expect(try InstrumentPatch.read(updated.archive()) == updated)
    capture.second = 0.79
    #expect(capture.bounds == nil)
    #expect(throws: ExpressivePresetError.invalidPatch) { try capture.applying(to: patch) }
}

@Test func airTemplatesAppendAtomicallyAndRejectTargetCollision() throws {
    let original = InstrumentPatch.starter
    #expect(throws: ExpressivePresetError.targetConflict) {
        try AirInstrumentPreset.theremin.appending(to: original, channel: 0)
    }
    let result = try AirInstrumentPreset.theremin.appending(to: original, channel: 1)
    #expect(Array(result.routes.prefix(original.routes.count)) == original.routes)
    #expect(try PatchGraph(patch: result).compile(name: result.name) == result)
}
