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
    }
}
