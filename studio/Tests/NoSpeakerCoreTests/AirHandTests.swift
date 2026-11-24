import Testing
@testable import NoSpeakerCore

private func point(_ x: Double, _ y: Double, confidence: Double = 0.9) -> AirHandPoint {
    .init(x: x, y: y, confidence: confidence)
}

@Test func airHandRejectsLowConfidenceAndDegeneratePalm() {
    #expect(AirHandSample(thumb: point(0.2,0.2,confidence: 0.3), index: point(0.4,0.2),
                          wrist: point(0.3,0.1), middleBase: point(0.3,0.3)) == nil)
    #expect(AirHandSample(thumb: point(0.2,0.2), index: point(0.4,0.2),
                          wrist: point(0.3,0.1), middleBase: point(0.3,0.1)) == nil)
}

@Test func airHandApertureNormalizedAndIndependentOfScale() throws {
    let a = try #require(AirHandSample(thumb: point(0.2,0.2), index: point(0.35,0.2),
                                      wrist: point(0.3,0.1), middleBase: point(0.3,0.3)))
    let b = try #require(AirHandSample(thumb: point(0.4,0.4), index: point(0.7,0.4),
                                      wrist: point(0.6,0.2), middleBase: point(0.6,0.6)))
    #expect(abs(a.aperture - 0.5) < 0.00001)
    #expect(abs(a.aperture - b.aperture) < 0.00001)
}

@Test func airHandRoutesWahAndReleasesOnLossWithoutOtherSource() throws {
    let wah = SensorDestination(.controlChange, number: 4)
    let note = SensorDestination(.note, number: 60)
    let patch = InstrumentPatch(routes: [
        .init(id: "wah", source: .camera, signal: .gesture, destination: wah),
        .init(id: "note", source: .trackpad, signal: .contact, destination: note)
    ])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let hand = try #require(AirHandSample(thumb: point(0.2,0.2), index: point(0.35,0.2),
                                        wrist: point(0.3,0.1), middleBase: point(0.3,0.3)))
    let touch = runtime.receive(source: .trackpad, x: 0.5, y: 0.5, size: 0.5, hostTime: 1, now: 1)
    #expect(touch == [.init(note, value: 100)])
    let air = runtime.receiveHand(hand, hostTime: 1.1, now: 1.1)
    #expect(air.count == 1 && (63...64).contains(air[0].value))
    #expect(runtime.receiveHand(nil, hostTime: 1.2, now: 1.2) == [.init(wah, value: 0)])
    #expect(runtime.activeSources == [.trackpad])
    #expect(runtime.stop() == [.init(note, value: 0)])
}

@Test func airHandWatchdogAndStaleFrameFence() throws {
    let note = SensorDestination(.note, number: 60)
    let patch = InstrumentPatch(routes: [.init(id: "air", source: .camera, signal: .contact, destination: note)])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let hand = try #require(AirHandSample(thumb: point(0.2,0.2), index: point(0.35,0.2),
                                        wrist: point(0.3,0.1), middleBase: point(0.3,0.3)))
    #expect(runtime.receiveHand(hand, hostTime: 1, now: 2).isEmpty)
    #expect(runtime.receiveHand(hand, hostTime: 2, now: 2) == [.init(note, value: 100)])
    #expect(runtime.expire(now: 2.4) == [.init(note, value: 0)])
    #expect(runtime.stop().isEmpty)
    #expect(runtime.receiveHand(hand, hostTime: 3, now: 3).isEmpty)
}
