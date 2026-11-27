import Foundation
import XCTest
@testable import NoSpeakerCore

final class SequencerPatternArchiveTests: XCTestCase {
    private func edit(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testNoteRoundTripPreservesMusicalCellsAndSeededTake() throws {
        var groove = GrooveSettings()
        groove.swing = 67
        groove.humanize = 48
        groove.seed = 987
        let notes = NoteSequence(bpm: 87.5, length: 16, steps: [
            .init(index: 8, midi: 62, velocity: 0, gate: 0.25),
            .init(index: 1, midi: 60, velocity: 0.5, gate: 1),
            .init(index: 0, midi: 60, velocity: 0.8, gate: 1),
            .init(index: 15, midi: nil, velocity: 0.25, gate: 0.2)
        ])
        let archive = try SequencerPatternArchive(notes: notes, channel: 4, loop: true, groove: groove)
        let bytes = try archive.encoded()
        let restored = try SequencerPatternArchive.decode(bytes)
        XCTAssertEqual(archive, restored)
        XCTAssertEqual(try restored.encoded(), bytes)
        XCTAssertTrue(restored.loop)
        XCTAssertEqual(restored.channel, 4)
        XCTAssertEqual(restored.groove, groove)
        let draft = try XCTUnwrap(restored.noteDraft())
        XCTAssertEqual(draft.bpm, 87.5)
        XCTAssertEqual(draft.length, 16)
        XCTAssertEqual(draft.stepsPerBeat, 4)
        XCTAssertEqual(draft.steps.map(\.index), [0, 1, 8, 15])
        XCTAssertEqual(draft.steps.map(\.midi), [60, 60, 62, nil])
        XCTAssertEqual(draft.steps.map(\.velocity), [0.8, 0.5, 0, 0.25])
        XCTAssertEqual(draft.steps.map(\.gate), [1, 1, 0.25, 0.2])
        XCTAssertNil(restored.drumDraft())
        let take = try restored.frozen()
        XCTAssertEqual(take, try archive.frozen())
        XCTAssertEqual(take.clip.notes.count, 2)
        XCTAssertTrue(take.clip.notes.allSatisfy { $0.channel == 4 })
        XCTAssertLessThanOrEqual(take.clip.notes[0].start + take.clip.notes[0].duration,
                                 take.clip.notes[1].start)
        XCTAssertEqual(try take.schedule().events, try archive.frozen().schedule().events)
    }

    func testDrumCanonicalOrderIgnoresTransientIdentityAndInputOrder() throws {
        let hits: [DrumStep] = [
            .init(index: 3, voice: .openHat, velocity: 0.4),
            .init(index: 0, voice: .snare, velocity: 0.5),
            .init(index: 0, voice: .kick, velocity: 1),
            .init(index: 2, voice: .tom, velocity: 0)
        ]
        let a = try SequencerPatternArchive(drums: .init(bpm: 140, hits: hits))
        let b = try SequencerPatternArchive(drums: .init(bpm: 140, hits: Array(hits.reversed())))
        XCTAssertEqual(try a.encoded(), try b.encoded())
        let restored = try SequencerPatternArchive.decode(a.encoded())
        XCTAssertEqual(a, restored)
        XCTAssertNil(restored.noteDraft())
        XCTAssertNil(restored.channel)
        let draft = try XCTUnwrap(restored.drumDraft())
        XCTAssertEqual(draft.hits.map(\.voice), [.kick, .snare, .tom, .openHat])
        XCTAssertEqual(draft.hits.map(\.velocity), [1, 0.5, 0, 0.4])
        let take = try restored.frozen()
        XCTAssertEqual(take.clip.notes.map(\.pitch), [36, 38, 46])
        XCTAssertEqual(take.clip.notes.map(\.channel), [9, 9, 9])
    }

    func testEmptyAndMutedDraftsSaveButCannotPlay() throws {
        let note = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: nil), .init(index: 1, midi: 60, velocity: 0)
        ]))
        let drum = try SequencerPatternArchive(drums: .init())
        for archive in [note, drum] {
            let restored = try SequencerPatternArchive.decode(archive.encoded())
            XCTAssertEqual(restored, archive)
            XCTAssertThrowsError(try restored.frozen()) {
                XCTAssertEqual($0 as? MIDIClipError, .empty)
            }
        }
    }

    func testInvalidVersionSchemaAndCrossKindPayloadRejected() throws {
        let bytes = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)])).encoded()
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes) { $0["version"] = 2 })) {
            XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .unsupportedVersion)
        }
        for change: (inout [String: Any]) -> Void in [
            { $0["kind"] = "unknown" },
            { $0["hits"] = [] },
            { $0["tuning"] = ["cents": 23] },
            { $0.removeValue(forKey: "channel") },
            { $0["loop"] = "true" },
            { $0["notes"] = [["index": 0, "midi": 60, "velocity": 1, "gate": 1, "pitchBend": 42]] },
            { $0["notes"] = [["index": 0, "midi": 60, "velocity": 1]] }
        ] {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes, change)))
        }
    }

    func testImportRevalidatesGridEvenWhenCellsWouldBeSilent() throws {
        let bytes = try SequencerPatternArchive(notes: .init()).encoded()
        for change: (inout [String: Any]) -> Void in [
            { $0["bpm"] = 0 },
            { $0["stepsPerBeat"] = 7 },
            { $0["length"] = 4097 },
            { $0["channel"] = 16 },
            { $0["notes"] = [["index": -1, "velocity": 0, "gate": 0.8]] },
            { $0["notes"] = [["index": 0, "midi": 128, "velocity": 0, "gate": 0.8]] },
            { $0["notes"] = [["index": 0, "velocity": 1, "gate": 0.01]] },
            { $0["notes"] = [["index": 0, "velocity": 0, "gate": 0.8],
                             ["index": 0, "velocity": 0, "gate": 0.8]] }
        ] {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes, change)))
        }
        let drums = try SequencerPatternArchive(drums: .init()).encoded()
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(drums) {
            $0["hits"] = [["index": 0, "voice": "kick", "velocity": 0],
                          ["index": 0, "voice": "kick", "velocity": 0]]
        }))
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(drums) {
            $0["hits"] = [["index": 0, "voice": "unknown", "velocity": 1]]
        }))
    }

    func testGrooveMustBeCompleteAndValidEvenInEmptyDraft() throws {
        let bytes = try SequencerPatternArchive(notes: .init(), groove: GrooveSettings()).encoded()
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes) { $0["stepsPerBeat"] = 8 }))
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes) { $0["groove"] = ["seed": 1] }))
        XCTAssertThrowsError(try SequencerPatternArchive.decode(edit(bytes) {
            $0["groove"] = ["swing": 50, "humanize": 0, "intensity": 100, "accent": 0,
                            "probability": 100, "seed": 0]
        }))
    }

    func testBoundedBytesAndMalformedJSON() throws {
        for data in [Data(), Data(repeating: 32, count: SequencerPatternArchive.maximumBytes + 1)] {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(data)) {
                XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .invalidSize)
            }
        }
        for text in ["[]", "{", "null", "true"] {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(Data(text.utf8)))
        }
    }

    func testRestoredTakeUsesExistingBoundedSchedulerAndRetiresOnStop() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60, gate: 1), .init(index: 1, midi: 60, gate: 1)
        ]))
        let take = try SequencerPatternArchive.decode(original.encoded()).frozen()
        var playback = try BoundedMIDIPlayback(clip: take.clip)
        let originalEvents = try BoundedMIDIPlayback(clip: original.frozen().clip).events
        XCTAssertEqual(playback.events, originalEvents)
        XCTAssertTrue(try playback.begin(now: 1000))
        var sent: [SensorCommand] = []
        playback.advance(now: 1000, send: { sent.append($0); return true })
        playback.stop(send: { sent.append($0); return true })
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertTrue(playback.outstanding.isEmpty)
        XCTAssertEqual(sent.map(\.value), [108, 0])
        playback.advance(now: 125_001_000, send: { sent.append($0); return true })
        XCTAssertEqual(sent.count, 2)
    }

    func testDuplicateJSONKeysRejectedAtEveryObjectLevel() throws {
        let cases = [
            #"{"version":1,"kind":"notes","bpm":120,"bpm":0,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[]}"#,
            #"{"version":1,"kind":"notes","bpm":0,"bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[]}"#,
            #"{"version":1,"kind":"notes","bpm":120,"\u0062pm":0,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[]}"#,
            #"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[{"index":0,"midi":60,"midi":128,"velocity":1,"gate":1}]}"#,
            #"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[{"index":0,"midi":128,"midi":60,"velocity":1,"gate":1}]}"#,
            #"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[{"index":0,"midi":60,"velocity":1,"gate":1,"\u0067ate":0}]}"#,
            #"{"version":1,"kind":"drums","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"hits":[{"index":0,"voice":"kick","voice":"unknown","velocity":1}]}"#,
            #"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[],"groove":{"swing":50,"humanize":0,"intensity":100,"accent":0,"probability":100,"seed":1,"seed":0}}"#
        ]
        for input in cases {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(Data(input.utf8)), input) {
                XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .duplicateKey)
            }
        }
    }

    func testUniqueEscapedKeysAndRepeatedKeysAcrossCellsAccepted() throws {
        let input = #"{"version":1,"kind":"notes","\u0062pm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[{"index":0,"midi":60,"velocity":1,"gate":1},{"index":1,"midi":61,"velocity":1,"gate":1}]}"#
        let archive = try SequencerPatternArchive.decode(Data(input.utf8))
        XCTAssertEqual(archive.noteDraft()?.steps.map(\.midi), [60, 61])
        XCTAssertEqual(archive.noteDraft()?.bpm, 120)
        XCTAssertEqual(archive, try SequencerPatternArchive.decode(archive.encoded()))
    }

    func testArchivePreflightRejectsDepthEncodingAndExcessFields() throws {
        let base = #"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[]}"#
        let inputs = [
            base.replacingOccurrences(of: #""notes":[]"#, with: #""notes":[[[[]]]]"#),
            base.replacingOccurrences(of: #""notes":[]"#, with: #""notes":[{"index":0,"midi":60,"velocity":1,"gate":1,"unknown":"\\\"{}[]:"}]"#),
            base.replacingOccurrences(of: #""notes":[]"#, with: #""notes":[],"unknown":0,"extra":1"#),
            String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        ]
        for input in inputs {
            XCTAssertThrowsError(try SequencerPatternArchive.decode(Data(input.utf8))) {
                XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .invalidSchema)
            }
        }
        let utf16 = try XCTUnwrap(base.data(using: .utf16LittleEndian))
        XCTAssertThrowsError(try SequencerPatternArchive.decode(utf16)) {
            XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .invalidSchema)
        }
    }

    func testMaximumHitCountRoundTripRemainsWithinArchiveByteLimit() throws {
        let hits = (0..<4096).flatMap { index in
            DrumVoice.allCases.map { DrumStep(index: index, voice: $0, velocity: 0.12345678901234567) }
        }.prefix(16_384)
        let archive = try SequencerPatternArchive(drums: .init(length: 4096, hits: Array(hits)))
        let data = try archive.encoded()
        XCTAssertLessThanOrEqual(data.count, SequencerPatternArchive.maximumBytes)
        let restored = try SequencerPatternArchive.decode(data)
        XCTAssertEqual(restored, archive)
        XCTAssertEqual(restored.drumDraft()?.hits.count, 16_384)
    }

    func testSignedZeroVelocityHasCanonicalIdentityForNotesAndDrums() throws {
        let precision = 0.12345678901234567
        let negativeNote = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60, velocity: -0.0),
            .init(index: 1, midi: 62, velocity: precision)
        ]))
        let positiveNote = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60, velocity: 0.0),
            .init(index: 1, midi: 62, velocity: precision)
        ]))
        let negativeDrum = try SequencerPatternArchive(drums: .init(hits: [
            .init(index: 0, voice: .kick, velocity: -0.0),
            .init(index: 1, voice: .snare, velocity: precision)
        ]))
        let positiveDrum = try SequencerPatternArchive(drums: .init(hits: [
            .init(index: 0, voice: .kick, velocity: 0.0),
            .init(index: 1, voice: .snare, velocity: precision)
        ]))
        for (negative, positive) in [(negativeNote, positiveNote), (negativeDrum, positiveDrum)] {
            XCTAssertEqual(negative, positive)
            XCTAssertEqual(try negative.encoded(), try positive.encoded())
            XCTAssertEqual(try negative.frozen(), try positive.frozen())
            var editor = try SequencerDraftEditor(draft: positive)
            XCTAssertFalse(try editor.replace(with: negative))
            XCTAssertFalse(editor.canUndo)
        }
        XCTAssertEqual(negativeNote.noteDraft()?.steps.first?.velocity.sign, .plus)
        XCTAssertEqual(negativeDrum.drumDraft()?.hits.first?.velocity.sign, .plus)
        XCTAssertEqual(negativeNote.noteDraft()?.steps.last?.velocity, precision)
        XCTAssertEqual(negativeDrum.drumDraft()?.hits.last?.velocity, precision)
    }

    func testImportedNegativeZeroVelocityNormalizesWithoutChangingOtherValues() throws {
        let note = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60, velocity: 0)]))
        let drum = try SequencerPatternArchive(drums: .init(hits: [.init(index: 0, voice: .kick, velocity: 0)]))
        for archive in [note, drum] {
            let expected = try archive.encoded()
            let json = String(decoding: expected, as: UTF8.self)
            for literal in ["-0", "-0.0", "-0e0"] {
                let input = json.replacingOccurrences(of: #""velocity":0"#, with: "\"velocity\":" + literal)
                XCTAssertNotEqual(json, input)
                let decoded = try SequencerPatternArchive.decode(Data(input.utf8))
                XCTAssertEqual(decoded, archive)
                XCTAssertEqual(try decoded.encoded(), expected)
                XCTAssertThrowsError(try decoded.frozen())
            }
        }
    }
}
