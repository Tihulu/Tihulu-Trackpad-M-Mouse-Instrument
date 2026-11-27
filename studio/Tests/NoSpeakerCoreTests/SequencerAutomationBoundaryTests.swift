import Foundation
import XCTest
@testable import NoSpeakerCore

/// Compatibility inventory, not a claim of continuous automation support.
/// Preserve the note-only contract until a separate schema is approved.
final class SequencerAutomationBoundaryTests: XCTestCase {
    func testExistingMIDIParserProjectsNotesNotContinuousAutomation() throws {
        let nominal: [(Int, [UInt8])] = [
            (0, [0x90, 60, 100]), (480, [0x80, 60, 0])
        ]
        let withAutomation: [(Int, [UInt8])] = [
            (0, [0xB0, 74, 32]), (0, [0x90, 60, 100]),
            (120, [0xB0, 74, 96]), (240, [0xE0, 0, 72]),
            (480, [0x80, 60, 0]), (480, [0xE0, 0, 64])
        ]
        let plain = try MIDIFileParser.parse(MIDIClipWriter.encodeEvents(bpm: 120, length: 960, events: nominal))
        let mixed = try MIDIFileParser.parse(MIDIClipWriter.encodeEvents(bpm: 120, length: 960, events: withAutomation))
        XCTAssertEqual(plain, mixed)
        XCTAssertEqual(mixed.notes.count, 1)
        XCTAssertEqual(mixed.notes.first?.note, 60)
        XCTAssertEqual(mixed.notes.first?.velocity, 100)
        // The parser exposes no automation track or receiver-reference evidence.
        // Equal note projections do NOT imply equal MIDI performance.
    }

    func testBoundedNominalPlaybackPlanRejectsContinuousFields() throws {
        let valid = #"{"bpm":120,"length":960,"notes":[{"start":0,"duration":480,"channel":0,"pitch":60,"velocity":100}]}"#
        XCTAssertEqual(try BoundedMIDIPlanInput.decode(Data(valid.utf8)).notes.count, 1)
        for field in ["automation", "relative", "feedback", "reference", "cc74"] {
            let mixed = String(valid.dropLast()) + ",\"" + field + "\":64}"
            XCTAssertThrowsError(try BoundedMIDIPlanInput.decode(Data(mixed.utf8)), field)
        }
        let mixedNote = valid.replacingOccurrences(of: #""velocity":100"#, with: #""velocity":100,"bend":8192"#)
        XCTAssertThrowsError(try BoundedMIDIPlanInput.decode(Data(mixedNote.utf8)))
    }
}
