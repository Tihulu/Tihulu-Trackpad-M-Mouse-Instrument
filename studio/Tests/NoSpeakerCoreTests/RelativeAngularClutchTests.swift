import Testing
@testable import NoSpeakerCore

@Test func relativeAngleSeamBothDirections() throws {
    var clutch = try #require(RelativeAngularClutch(sweepDegrees: 10))
    #expect(clutch.begin(angle: 359, receipt: 1) == .anchored(0.5))
    #expect(clutch.update(angle: 1, receipt: 2) == .position(0.6))
    #expect(clutch.update(angle: 359, receipt: 3) == .position(0.5))
    #expect(clutch.update(angle: 357, receipt: 4) == .position(0.4))
    #expect(clutch.end() == .releaseRequired)
    #expect(clutch.begin(angle: 1, receipt: 5) == .anchored(0.5))
    #expect(clutch.update(angle: 359, receipt: 6) == .position(0.4))
}

@Test func relativeAngleSaturationPreservesOriginOnReturn() throws {
    var clutch = try #require(RelativeAngularClutch(sweepDegrees: 45))
    _ = clutch.begin(angle: 350, receipt: 1)
    #expect(clutch.update(angle: 80, receipt: 2) == .position(1))
    #expect(clutch.update(angle: 170, receipt: 3) == .position(1))
    #expect(clutch.update(angle: 80, receipt: 4) == .position(1))
    #expect(clutch.update(angle: 350, receipt: 5) == .position(0.5))
}

@Test func relativeAngleFaultNeedsExplicitReleaseAndFreshReceipt() throws {
    var clutch = try #require(RelativeAngularClutch())
    _ = clutch.begin(angle: 0, receipt: 1)
    #expect(clutch.update(angle: 180, receipt: 2) == .releaseRequired)
    #expect(clutch.update(angle: 1, receipt: 3) == .blocked)
    #expect(clutch.begin(angle: 1, receipt: 3) == .blocked)
    _ = clutch.end()
    #expect(clutch.begin(angle: 1, receipt: 2) == .blocked)
    _ = clutch.end()
    #expect(clutch.begin(angle: 1, receipt: 4) == .anchored(0.5))
    #expect(clutch.update(angle: .nan, receipt: 5) == .releaseRequired)
    _ = clutch.end()
    #expect(clutch.begin(angle: 360, receipt: 6) == .blocked)
}

@Test func relativeAngleRejectsAmbiguousStepAndDuplicateTime() throws {
    var clutch = try #require(RelativeAngularClutch(maximumStepDegrees: 20))
    _ = clutch.begin(angle: 10, receipt: 1)
    #expect(clutch.update(angle: 31, receipt: 2) == .releaseRequired)
    _ = clutch.end()
    _ = clutch.begin(angle: 10, receipt: 3)
    #expect(clutch.update(angle: 11, receipt: 3) == .releaseRequired)
    #expect(RelativeAngularClutch(sweepDegrees: .nan) == nil)
    #expect(RelativeAngularClutch(maximumStepDegrees: 180) == nil)
}

@Test func relativeAngleFeedsExistingGestureExactlyOnce() throws {
    var clutch = try #require(RelativeAngularClutch(sweepDegrees: 10))
    guard case .anchored(let origin) = clutch.begin(angle: 359, receipt: 1) else { Issue.record("No origin"); return }
    var gesture = try #require(RelativeControlGesture(input: origin, timestamp: 1, reference: 64, lower: 0, upper: 127))
    guard case .position(let value) = clutch.update(angle: 1, receipt: 2) else { Issue.record("No position"); return }
    #expect(gesture.update(input: value, timestamp: 2) == 77)
    guard case .position(let returned) = clutch.update(angle: 359, receipt: 3) else { Issue.record("No return"); return }
    #expect(gesture.update(input: returned, timestamp: 3) == 64)
}

@Test func relativeAngleTravelBoundRetiresInsteadOfLosingOrigin() throws {
    var clutch = try #require(RelativeAngularClutch())
    _ = clutch.begin(angle: 0, receipt: 0)
    for i in 1...40 {
        #expect(clutch.update(angle: Double((i * 90) % 360), receipt: Double(i)) == .position(1))
    }
    #expect(clutch.update(angle: 90, receipt: 41) == .releaseRequired)
    #expect(clutch.update(angle: 0, receipt: 42) == .blocked)
}
