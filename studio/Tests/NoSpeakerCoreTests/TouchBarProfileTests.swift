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
            (.filter, .filter, 0), (.wah, .wah, 0), (.vibrato, .vibrato, 0),
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

extension TouchBarProfileTests {
    func testWahZoneAndTiltRoundTripWithoutChangingDefaults() throws {
        XCTAssertFalse(TouchBarProfile().zones.contains(.wah))
        let profile = TouchBarProfile(zones: [.keys, .wah, .wah], tiltTarget: .wah)
        let restored = try JSONDecoder().decode(TouchBarProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.normalized().zones, [.keys, .wah])
        XCTAssertEqual(restored.neutralTilt?.value, 0)
    }
}

extension TouchBarProfileTests {
    func testRibbonNeutralAndInitialPositions() {
        XCTAssertEqual(TouchBarZone.pitchBend.releasePosition,0.5)
        XCTAssertEqual(TouchBarZone.fretless.releasePosition,0.5)
        XCTAssertNil(TouchBarZone.expression.releasePosition)
        XCTAssertNil(TouchBarZone.wah.releasePosition)
        XCTAssertEqual(TouchBarZone.expression.initialPosition,1)
        XCTAssertEqual(TouchBarZone.pitchBend.initialPosition,0.5)
        XCTAssertEqual(TouchBarZone.wah.initialPosition,0)
    }
    func testNonFiniteTiltSettingsNormalizeToFiniteRange() {
        let profile = TouchBarProfile(tiltTarget:.pitchBend,tiltMinDegrees:.nan,tiltMaxDegrees:.infinity)
        XCTAssertEqual(profile.normalized().tiltMinDegrees,90)
        XCTAssertEqual(profile.normalized().tiltMaxDegrees,120)
        XCTAssertEqual(profile.normalizedTilt(105),0.5)
    }
}

extension TouchBarProfileTests {
    func testPianoKeysMatchNormalizedBaseAcrossAllSupportedNotes() throws {
        for base in 0...115 {
            let profile=TouchBarProfile(baseNote:base)
            XCTAssertEqual(profile.pianoKeys.count,8)
            for (index,key) in profile.pianoKeys.enumerated() {
                XCTAssertEqual(key.note,base+index)
                XCTAssertEqual(try MusicTheory.midiNumber(note:key.label),key.note)
            }
        }
        XCTAssertEqual(TouchBarProfile(baseNote:62).pianoKeys.first?.label,"D4")
        XCTAssertEqual(TouchBarProfile(baseNote:-10).pianoKeys.first?.note,0)
        XCTAssertEqual(TouchBarProfile(baseNote:999).pianoKeys.last?.note,122)
    }
    func testVelocityRoundTripAndBounds() throws {
        let profile=TouchBarProfile(noteVelocity:77)
        XCTAssertEqual(try JSONDecoder().decode(TouchBarProfile.self,from:JSONEncoder().encode(profile)).noteVelocity,77)
        XCTAssertEqual(TouchBarProfile(noteVelocity:0).normalized().noteVelocity,1)
        XCTAssertEqual(TouchBarProfile(noteVelocity:128).normalized().noteVelocity,127)
    }
}
