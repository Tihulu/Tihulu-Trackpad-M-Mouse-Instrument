import Foundation
import Testing
@testable import NoSpeakerCore

private let palm = DepthXYZPoint(x: 0.4, y: 0.5, meters: 0.4, confidence: 0.8)

@Test func depthXYZNormalizesTheMeasuredVolumeInScreenCoordinates() throws {
    let volume = DepthXYZVolume(left: 0.2, right: 0.6, bottom: 0.4, top: 0.6, nearMeters: 0.2, farMeters: 1)
    let point = try #require(volume.normalize(palm))
    #expect(abs(point.x - 0.5) < 1e-12 && abs(point.y - 0.5) < 1e-12 && abs(point.z - 0.25) < 1e-12)
    #expect(volume.normalize(.init(x: 0.6, y: 0.4, meters: 1, confidence: 0.65)) == .init(x: 1, y: 0, z: 1))
    #expect(volume.normalize(.init(x: 0.61, y: 0.5, meters: 0.4, confidence: 1)) == nil)
    #expect(volume.normalize(.init(x: 0.4, y: 0.39, meters: 0.4, confidence: 1)) == nil)
    #expect(volume.normalize(.init(x: 0.4, y: 0.5, meters: 1.01, confidence: 1)) == nil)
    #expect(volume.normalize(.init(x: .nan, y: 0.5, meters: 0.4, confidence: 1)) == nil)
    #expect(volume.normalize(.init(x: 0.4, y: 0.5, meters: .infinity, confidence: 1)) == nil)
    #expect(volume.normalize(.init(x: 0.4, y: 0.5, meters: 0.4, confidence: 0.64)) == nil)
    #expect(try JSONDecoder().decode(DepthXYZVolume.self, from: JSONEncoder().encode(volume)) == volume)
}

@Test func depthXYZRejectsInvalidCalibration() {
    for bad in [DepthXYZVolume(left: 1), .init(right: 0.01), .init(top: .nan),
                .init(bottom: -0.01), .init(nearMeters: 0), .init(farMeters: 0.28), .init(farMeters: 4)] {
        #expect(!bad.isValid)
        #expect(bad.normalize(palm) == nil)
        #expect(DepthXYZTracking(volume: bad) == nil)
    }
}

@Test func depthXYZRequiresReacquisitionAndNeverReplaysBufferedSamples() throws {
    var tracker = try #require(DepthXYZTracking())
    #expect(tracker.observe(palm, at: 0, now: 0) == nil)
    #expect(tracker.observe(palm, at: 0.01, now: 0.01) != nil)
    #expect(tracker.observe(nil, at: 0.02, now: 0.03) == nil)
    #expect(tracker.observe(palm, at: 0.025, now: 0.031) == nil)
    #expect(tracker.observe(palm, at: 0.04, now: 0.04) == nil)
    #expect(tracker.observe(palm, at: 0.05, now: 0.05) != nil)
    let beforeDeadline = tracker.expire(now: 0.199)
    #expect(!beforeDeadline)
    let atDeadline = tracker.expire(now: 0.2)
    #expect(atDeadline)
    let afterRelease = tracker.expire(now: 0.21)
    #expect(!afterRelease)
    #expect(tracker.observe(palm, at: 0.19, now: 0.22) == nil)
    #expect(tracker.observe(palm, at: 0.23, now: 0.23) == nil)
    #expect(tracker.observe(palm, at: 0.24, now: 0.24) != nil)
}

@Test func depthXYZRejectsFutureStaleAndNonmonotonicClocksAndResetsOnGap() throws {
    var tracker = try #require(DepthXYZTracking())
    #expect(tracker.observe(palm, at: 0.01, now: 0) == nil)
    #expect(tracker.observe(palm, at: 0.1, now: 0.25) == nil)
    #expect(tracker.observe(palm, at: 0.26, now: 0.26) == nil)
    #expect(tracker.observe(palm, at: 0.27, now: 0.27) != nil)
    #expect(tracker.observe(palm, at: 0.42, now: 0.42) == nil)
    #expect(tracker.observe(palm, at: 0.43, now: 0.43) != nil)
    let clockRegressed = tracker.expire(now: 0.42)
    #expect(clockRegressed)
    #expect(tracker.observe(palm, at: 0.44, now: 0.44) == nil)
    #expect(tracker.observe(palm, at: 0.45, now: 0.45) != nil)
    tracker.reset()
    #expect(tracker.observe(palm, at: 0.45, now: 0.46) == nil)
    #expect(tracker.observe(palm, at: .infinity, now: .nan) == nil)
}

@Test func depthXYZKeysUseOnlyGrantedZonesAndForgetHysteresisOnLoss() throws {
    var keys = try #require(DepthXYZKeys(authorized: (1 << 3) | (1 << 15), axis: .y))
    #expect(keys.output(.init(x: 1,y: 0,z: 1)).keys == 1 << 3)
    #expect(keys.output(.init(x: 1,y: 0.53,z: 1)).keys == 1 << 3)
    #expect(keys.output(nil).keys == 0)
    #expect(keys.output(.init(x: 1,y: 0.53,z: 1)).keys == 1 << 15)
    #expect(keys.output(.init(x: 0,y: 1,z: 0)).keys == 1 << 15)
    #expect(DepthXYZKeys(authorized: RemotePiano.sustainBit, axis: .z) == nil)
}

@Test func depthXYZDelayedWatchdogRejectsBufferedReacquisition() throws {
    var tracker = try #require(DepthXYZTracking())
    #expect(tracker.observe(palm, at: 0, now: 0) == nil)
    #expect(tracker.observe(palm, at: 0.01, now: 0.01) != nil)
    // Both buffered stamps are individually fresh, but the old acquisition
    // expired at 0.16 before the delayed UI drain.
    #expect(tracker.observe(palm, at: 0.14, now: 0.17) == nil)
    #expect(tracker.observe(palm, at: 0.15, now: 0.171) == nil)
    #expect(tracker.observe(palm, at: 0.18, now: 0.18) == nil)
    #expect(tracker.observe(palm, at: 0.19, now: 0.19) != nil)
}
