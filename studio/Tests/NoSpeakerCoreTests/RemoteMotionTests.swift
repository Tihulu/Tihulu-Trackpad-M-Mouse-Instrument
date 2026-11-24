import Testing
@testable import NoSpeakerCore

@Test func remoteTiltValidatesAndCenters() throws {
    let neutral = try #require(RemoteOrientation(alpha: 359, beta: 10, gamma: -10))
    let cal = try #require(RemoteTiltCalibration(neutral: neutral, sweepDegrees: 40))
    let center = cal.normalize(neutral)
    #expect(center.yaw == 0.5)
    #expect(center.pitch == 0.5)
    #expect(center.roll == 0.5)
    let sample = try #require(RemoteOrientation(alpha: 1, beta: 30, gamma: -50))
    let values = cal.normalize(sample)
    #expect(abs(values.yaw - 0.525) < 0.000001)
    #expect(values.pitch == 0.75)
    #expect(values.roll == 0)
    #expect(RemoteOrientation(alpha: 360, beta: 0, gamma: 0) == nil)
    #expect(RemoteOrientation(alpha: 0, beta: .nan, gamma: 0) == nil)
    #expect(RemoteOrientation(alpha: 0, beta: 0, gamma: 91) == nil)
    #expect(RemoteTiltCalibration(neutral: neutral, sweepDegrees: 0) == nil)
    #expect(RemoteTiltCalibration(neutral: neutral, sweepDegrees: .infinity) == nil)
}

@Test func remoteTiltWrapsBetaAndSaturates() throws {
    let neutral = try #require(RemoteOrientation(alpha: 1, beta: 179, gamma: 0))
    let cal = try #require(RemoteTiltCalibration(neutral: neutral, sweepDegrees: 20))
    let sample = try #require(RemoteOrientation(alpha: 359, beta: -179, gamma: 90))
    let values = cal.normalize(sample)
    #expect(abs(values.yaw - 0.45) < 0.000001)
    #expect(abs(values.pitch - 0.55) < 0.000001)
    #expect(values.roll == 1)
}

@Test func remoteMotionMagnitudesRejectOutliers() {
    #expect(RemoteMotionNormalizer.acceleration(x: 0, y: 0, z: 0) == 0)
    #expect(RemoteMotionNormalizer.acceleration(x: 6, y: 8, z: 0) == 0.5)
    #expect(RemoteMotionNormalizer.acceleration(x: 30, y: 0, z: 0) == 1)
    #expect(RemoteMotionNormalizer.rotationRate(x: 0, y: -180, z: 0) == 0.5)
    #expect(RemoteMotionNormalizer.rotationRate(x: 0, y: 0, z: 2001) == nil)
    #expect(RemoteMotionNormalizer.acceleration(x: .nan, y: 0, z: 0) == nil)
    #expect(RemoteMotionNormalizer.acceleration(x: 0, y: .infinity, z: 0) == nil)
    #expect(RemoteMotionNormalizer.acceleration(x: 101, y: 0, z: 0) == nil)
}

@Test func remoteMotionFreshnessDisarmsOnReplayAndGap() {
    var gate = RemoteMotionFreshness()
    #expect(!gate.accept(receipt: 1, now: 1))
    #expect(gate.arm(receipt: 1, now: 1))
    #expect(gate.accept(receipt: 1.1, now: 1.12))
    #expect(!gate.accept(receipt: 1.1, now: 1.13))
    #expect(!gate.isArmed)
    #expect(!gate.accept(receipt: 1.2, now: 1.2))
    #expect(gate.arm(receipt: 2, now: 2))
    #expect(!gate.accept(receipt: 2.4, now: 2.4))
    #expect(!gate.isArmed)
    #expect(gate.arm(receipt: 3, now: 3))
    #expect(!gate.accept(receipt: 3.2, now: 3.1))
    #expect(!gate.isArmed)
}

@Test func remoteMotionFreshnessExpiresOnceAndStreamsAreIndependent() {
    var orientation = RemoteMotionFreshness()
    var acceleration = RemoteMotionFreshness()
    #expect(orientation.arm(receipt: 10, now: 10))
    #expect(acceleration.arm(receipt: 10, now: 10))
    #expect(acceleration.accept(receipt: 10.25, now: 10.25))
    #expect(orientation.expire(now: 10.4))
    #expect(!orientation.expire(now: 10.4))
    #expect(!acceleration.expire(now: 10.4))
    #expect(acceleration.expire(now: .nan))
    #expect(!orientation.arm(receipt: 10, now: 11))
    #expect(!orientation.arm(receipt: -1, now: 0))
}
