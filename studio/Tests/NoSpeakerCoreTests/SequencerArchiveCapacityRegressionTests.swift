import Foundation
import XCTest
@testable import NoSpeakerCore

/// Test-only candidate for the v1 archive capacity contract. No live MIDI or hardware.
final class SequencerArchiveCapacityRegressionTests: XCTestCase {
    private func largePattern() -> DrumSequence {
        let voices: [DrumVoice] = [.closedHat, .openHat, .snare, .clap]
        let hits = (0..<4096).flatMap { index in
            voices.map { DrumStep(index: index, voice: $0, velocity: 0.00012345678901234567) }
        }
        return .init(bpm: 300, stepsPerBeat: 4, length: 4096, hits: hits)
    }
    private func groove() -> GrooveSettings {
        var g = GrooveSettings()
        g.swing = 75; g.humanize = 100; g.intensity = 125
        g.accent = 30; g.probability = 100; g.seed = 9999
        return g
    }
    private func assertInvalidSize(_ expression: @autoclosure () throws -> Any,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual($0 as? SequencerPatternArchive.ArchiveError, .invalidSize, file: file, line: line)
        }
    }
    func testValidGridCanExceedArchiveByteLimit() throws {
        let grid = largePattern()
        XCTAssertEqual(grid.hits.count, 16_384)
        let archive = try SequencerPatternArchive(drums: grid, loop: true, groove: groove())
        XCTAssertEqual(archive.drumDraft()?.hits.count, 16_384)
        assertInvalidSize(try archive.encoded())
        assertInvalidSize(try SequencerDraftEditor(draft: archive))
    }
    func testOversizedReplacementAndBatchEditPreserveUndo() throws {
        let initial = try SequencerPatternArchive(drums: .init(hits: [.init(index: 0, voice: .kick, velocity: 0.9)]))
        var editor = try SequencerDraftEditor(draft: initial)
        XCTAssertTrue(try editor.setOptions(loop: true, groove: nil))
        let baseline = editor.draft
        let bytes = try baseline.encoded()
        let grid = largePattern()
        let oversized = try SequencerPatternArchive(drums: grid, loop: true, groove: groove())
        assertInvalidSize(try editor.replace(with: oversized))
        XCTAssertEqual(editor.draft, baseline)
        XCTAssertEqual(try editor.draft.encoded(), bytes)
        XCTAssertTrue(editor.canUndo)
        assertInvalidSize(try editor.editDrumsAndOptions { drums, options in
            drums = grid
            options.groove = groove()
        })
        XCTAssertEqual(editor.draft, baseline)
        XCTAssertEqual(try editor.draft.encoded(), bytes)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, initial)
        XCTAssertFalse(editor.canUndo)
    }
    func testByteBoundaryImportIsAtomic() throws {
        let initial = try SequencerPatternArchive(drums: .init(hits: [.init(index: 0, voice: .kick, velocity: 0.9)]))
        let encoded = try initial.encoded()
        XCTAssertLessThan(encoded.count, SequencerPatternArchive.maximumBytes)
        var padded = encoded
        padded.append(Data(repeating: 32, count: SequencerPatternArchive.maximumBytes - padded.count))
        XCTAssertEqual(padded.count, SequencerPatternArchive.maximumBytes)
        XCTAssertEqual(try SequencerPatternArchive.decode(padded), initial)
        padded.append(32)
        assertInvalidSize(try SequencerPatternArchive.decode(padded))
        var editor = try SequencerDraftEditor(draft: initial)
        XCTAssertTrue(try editor.setOptions(loop: true, groove: nil))
        let baseline = editor.draft
        assertInvalidSize(try editor.replaceImported(padded))
        XCTAssertEqual(editor.draft, baseline)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, initial)
    }
    func testCompactInputCannotExpandBeyondExportLimit() throws {
        let (compact, small, byteCount, count) = compactInput()
        XCTAssertEqual(compact.count, byteCount)
        XCTAssertLessThanOrEqual(compact.count, SequencerPatternArchive.maximumBytes)
        XCTAssertGreaterThan(count, 0)
        assertInvalidSize(try SequencerPatternArchive.decode(compact))
        let restored = try SequencerPatternArchive.decode(small)
        XCTAssertEqual(restored.drumDraft()?.hits.count, 1)
        XCTAssertEqual(try SequencerPatternArchive.decode(restored.encoded()), restored)
    }
    private func compactInput() -> (Data, Data, Int, Int) {
        let voices = ["clap", "closedHat", "openHat", "snare"]
        let header = #"{"version":1,"kind":"drums","bpm":300,"stepsPerBeat":4,"length":4096,"loop":true,"hits":["#
        var cells: [String] = []
        var byteCount = header.utf8.count + 2
        outer: for index in 0..<4096 {
            for voice in voices {
                let cell = #"{"index":\#(index),"voice":"\#(voice)","velocity":12345678901234567e-20}"#
                let nextCount = byteCount + cell.utf8.count + (cells.isEmpty ? 0 : 1)
                guard nextCount <= SequencerPatternArchive.maximumBytes else { break outer }
                cells.append(cell)
                byteCount = nextCount
            }
        }
        return (Data((header + cells.joined(separator: ",") + "]}").utf8), Data((header + cells.prefix(1).joined(separator: ",") + "]}").utf8), byteCount, cells.count)
    }

    func testRejectedCompactImportPreservesEntireBoundedUndoHistory() throws {
        let initial = try SequencerPatternArchive(drums: .init(hits: [.init(index: 0, voice: .kick, velocity: 0.9)]))
        var editor = try SequencerDraftEditor(draft: initial)
        var snapshots = [initial]
        for i in 1...20 {
            XCTAssertTrue(try editor.editDrums { $0.bpm = Double(120 + i) })
            snapshots.append(editor.draft)
        }
        let (compact, _, _, _) = compactInput()
        let baseline = editor.draft
        assertInvalidSize(try editor.replaceImported(compact))
        XCTAssertEqual(editor.draft, baseline)
        for expected in snapshots.dropLast().suffix(16).reversed() {
            XCTAssertTrue(editor.canUndo)
            XCTAssertTrue(editor.undo())
            XCTAssertEqual(editor.draft, expected)
        }
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.undo())
        XCTAssertEqual(editor.draft, snapshots[4])
    }

    func testCompactValidImportIsOneUndoAndCanonicalNoOp() throws {
        let initial = try SequencerPatternArchive(drums: .init(hits: [.init(index: 0, voice: .kick, velocity: 0.9)]))
        var editor = try SequencerDraftEditor(draft: initial)
        let (_, small, _, _) = compactInput()
        XCTAssertTrue(try editor.replaceImported(small))
        let accepted = editor.draft
        XCTAssertEqual(accepted.drumDraft()?.hits.first?.velocity, 0.00012345678901234567)
        XCTAssertFalse(try editor.replaceImported(accepted.encoded()))
        XCTAssertFalse(try editor.replaceImported(small))
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, initial)
        XCTAssertFalse(editor.canUndo)
    }

    func testNoteImportPreservesPrecisionAndRest() throws {
        let input = Data(#"{"version":1,"kind":"notes","bpm":120,"stepsPerBeat":4,"length":16,"loop":false,"channel":0,"notes":[{"index":0,"midi":60,"velocity":12345678901234567e-20,"gate":5e-2},{"index":1,"velocity":0,"gate":1}]}"#.utf8)
        let archive = try SequencerPatternArchive.decode(input)
        let notes = try XCTUnwrap(archive.noteDraft())
        XCTAssertEqual(notes.steps.first?.velocity, 0.00012345678901234567)
        XCTAssertEqual(notes.steps.first?.gate, 0.05)
        XCTAssertNil(notes.steps.last?.midi)
        XCTAssertEqual(archive, try SequencerPatternArchive.decode(archive.encoded()))
    }
}
