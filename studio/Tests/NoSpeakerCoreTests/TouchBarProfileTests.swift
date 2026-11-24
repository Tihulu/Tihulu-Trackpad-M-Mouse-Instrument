import XCTest
@testable import NoSpeakerCore

final class TouchBarProfileTests: XCTestCase {
    func testCustomZonesCanBeSelectedTogether() {
        var profile = TouchBarProfile()
        profile.zones = [.vibrato, .sustain, .pitchBend, .vibrato]
        XCTAssertEqual(profile.normalized().zones, [.vibrato, .sustain, .pitchBend])
    }
    func testChordZoneIsOptInAndCompatibleWithExistingZones() throws {
        XCTAssertFalse(TouchBarProfile().zones.contains(.chords))
        let profile = TouchBarProfile(zones: [.chords, .sustain, .pitchBend, .chords])
        XCTAssertEqual(profile.normalized().zones, [.chords, .sustain, .pitchBend])
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(TouchBarProfile.self, from: data).normalized(),
                       profile.normalized())
    }
    func testEmptyLayoutStillHasAnEscapeHatch() {
        XCTAssertEqual(TouchBarProfile(zones: []).normalized().zones, [.keys])
    }
    func testTiltNormalizationAndClamping() {
        let profile = TouchBarProfile(tiltTarget: .filter, tiltMinDegrees: 50, tiltMaxDegrees: 150)
        XCTAssertEqual(profile.normalizedTilt(50), 0)
        XCTAssertEqual(profile.normalizedTilt(100), 0.5)
        XCTAssertEqual(profile.normalizedTilt(180), 1)
        XCTAssertNil(profile.normalizedTilt(.infinity))
    }
    func testDisabledTiltDoesNotSendMIDI() {
        XCTAssertNil(TouchBarProfile().normalizedTilt(90))
        XCTAssertNil(TouchBarProfile().neutralTilt)
    }
    func testTiltNeutralMatchesControllerAndCalibration() throws {
        let targets: [(TiltMIDITarget, TouchBarZone, Double)] = [
            (.filter, .filter, 0), (.vibrato, .vibrato, 0),
            (.expression, .expression, 1), (.pitchBend, .pitchBend, 0.5)
        ]
        for (target, zone, value) in targets {
            for (minimum, maximum) in [(50.0, 135.0), (0.0, 200.0), (170.0, 50.0)] {
                let profile = TouchBarProfile(tiltTarget: target, tiltMinDegrees: minimum, tiltMaxDegrees: maximum)
                let neutral = try XCTUnwrap(profile.neutralTilt)
                XCTAssertEqual(neutral.zone, zone)
                XCTAssertEqual(neutral.value, value)
                XCTAssertEqual(try XCTUnwrap(profile.normalizedTilt(neutral.angle)), value, accuracy: 0.000001)
            }
        }
    }
}
