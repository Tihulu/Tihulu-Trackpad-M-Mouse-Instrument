import Testing
@testable import NoSpeakerCore

private func trackingPose() throws -> AirHandSample {
    try #require(AirHandSample(thumb: .init(x: 0.1,y: 0.7,confidence: 0.9),
        index: .init(x: 0.25,y: 0.7,confidence: 0.9),
        wrist: .init(x: 0.2,y: 0.3,confidence: 0.9),
        middleBase: .init(x: 0.2,y: 0.5,confidence: 0.9)))
}

@Test func orientationChangesAxesNotAperture() throws {
    let sample = try trackingPose()
    let rotated = sample.oriented(.clockwise, mirrorX: false)
    #expect(abs(rotated.x - 0.7) < 0.00001)
    #expect(abs(rotated.y - 0.75) < 0.00001)
    #expect(rotated.aperture == sample.aperture)
    let mirrored = sample.oriented(.upright, mirrorX: true)
    #expect(mirrored.x == 0.75 && mirrored.y == sample.y)
}

@Test func trackingRequiresConsecutiveFreshSamplesAndImmediateLoss() throws {
    var gate = AirTrackingGate()
    let sample = try trackingPose()
    #expect(gate.accept(sample, at: 1, now: 1) == nil)
    #expect(gate.accept(sample, at: 1.1, now: 1.1) == sample)
    #expect(gate.accept(nil, at: 1.2, now: 1.2) == nil)
    #expect(gate.accept(sample, at: 1.3, now: 1.3) == nil)
    #expect(gate.accept(sample, at: 1.4, now: 1.4) == sample)
    #expect(gate.accept(sample, at: 2, now: 2) == nil)
    #expect(gate.accept(sample, at: 2.1, now: 2.1) == sample)
    #expect(gate.accept(sample, at: 2.1, now: 3) == nil)
    #expect(gate.accept(sample, at: 3.1, now: 3.1) == nil)
}

@Test func acquisitionGateReleasesNoteAndPreventsOneFrameRetrigger() throws {
    let sample = try trackingPose()
    var gate = AirTrackingGate()
    var runtime = PhysicalPatchRuntime()
    let target = SensorDestination(.note, number: 60)
    try runtime.configure(.init(routes: [.init(id: "hand", source: .camera, signal: .contact, destination: target)]))
    #expect(runtime.receiveHand(gate.accept(sample, at: 1, now: 1), hostTime: 1, now: 1).isEmpty)
    #expect(runtime.receiveHand(gate.accept(sample, at: 1.1, now: 1.1), hostTime: 1.1, now: 1.1) == [.init(target, value: 100)])
    #expect(runtime.receiveHand(gate.accept(nil, at: 1.2, now: 1.2), hostTime: 1.2, now: 1.2) == [.init(target, value: 0)])
    #expect(runtime.receiveHand(gate.accept(sample, at: 1.3, now: 1.3), hostTime: 1.3, now: 1.3).isEmpty)
}
