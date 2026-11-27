import Foundation
import XCTest
@testable import NoSpeakerCore

final class SequencerDraftEditorTests: XCTestCase {
    func testBatchNoteEditAndClearLeaveEarlierTakeFrozen() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60, velocity: 0.5, gate: 0.5),
            .init(index: 15, midi: nil, velocity: 0.25, gate: 0.2)
        ]), channel: 2, loop: true)
        var editor = try SequencerDraftEditor(draft: original)
        let active = try editor.frozen()
        XCTAssertTrue(try editor.editNotes {
            $0.bpm = 90
            $0.steps[0].velocity = 1
            $0.steps[0].gate = 1
        })
        let next = try editor.frozen()
        XCTAssertEqual(active.clip.bpm, 120)
        XCTAssertEqual(active.clip.notes.first?.duration, 120)
        XCTAssertEqual(active.clip.notes.first?.velocity, 64)
        XCTAssertEqual(next.clip.bpm, 90)
        XCTAssertEqual(next.clip.notes.first?.duration, 240)
        XCTAssertEqual(next.clip.notes.first?.velocity, 127)
        XCTAssertEqual(next.clip.notes.first?.channel, 2)
        XCTAssertTrue(next.loop)
        XCTAssertEqual(editor.draft.noteDraft()?.steps.last?.index, 15)
        XCTAssertTrue(try editor.editNotes { $0.steps.removeAll() })
        XCTAssertThrowsError(try editor.frozen())
        XCTAssertEqual(active, try original.frozen())
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(try editor.frozen(), next)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.undo())
    }

    func testInvalidOrThrowingBatchLeavesDraftAndUndoUntouched() throws {
        enum Aborted: Error { case edit }
        let original = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)]))
        var editor = try SequencerDraftEditor(draft: original)
        XCTAssertTrue(try editor.editNotes { $0.steps[0].midi = 62 })
        let changed = editor.draft
        XCTAssertThrowsError(try editor.editNotes {
            $0.bpm = 99
            $0.steps[0].gate = 0
        })
        XCTAssertThrowsError(try editor.editNotes {
            $0.steps.append(.init(index: 0, midi: 64))
        })
        XCTAssertThrowsError(try editor.editNotes {
            $0.steps.removeAll()
            throw Aborted.edit
        })
        XCTAssertEqual(editor.draft, changed)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testDrumVelocityAndOptionsPreserveOwnershipBoundaries() throws {
        let original = try SequencerPatternArchive(drums: .init(hits: [
            .init(index: 0, voice: .kick), .init(index: 0, voice: .snare, velocity: 0.5)
        ]))
        var editor = try SequencerDraftEditor(draft: original)
        let active = try editor.frozen()
        XCTAssertTrue(try editor.editDrums { $0.hits[1].velocity = 0 })
        var groove = GrooveSettings()
        groove.seed = 82
        XCTAssertTrue(try editor.setOptions(loop: true, groove: groove))
        let next = try editor.frozen()
        XCTAssertEqual(active.clip.notes.count, 2)
        XCTAssertEqual(next.clip.notes.count, 1)
        XCTAssertEqual(next.clip.notes.first?.channel, 9)
        XCTAssertTrue(next.loop)
        let edited = editor.draft
        XCTAssertThrowsError(try editor.setOptions(loop: false, groove: nil, channel: 3)) {
            XCTAssertEqual($0 as? SequencerDraftEditor.EditError, .drumChannel)
        }
        XCTAssertThrowsError(try editor.editNotes { $0.bpm = 100 })
        XCTAssertEqual(editor.draft, edited)
        XCTAssertTrue(editor.undo())
        XCTAssertFalse(editor.draft.loop)
        XCTAssertNil(editor.draft.groove)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
    }

    func testImportedReplacementIsExplicitSameKindAndUndoable() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)]))
        let other = try SequencerPatternArchive(notes: .init(bpm: 180, steps: [.init(index: 3, midi: 72)]),
                                                channel: 7, loop: true)
        var editor = try SequencerDraftEditor(draft: original)
        let bytes = try other.encoded()
        XCTAssertEqual(try SequencerPatternArchive.decode(bytes), other)
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(try editor.replaceImported(original.encoded()))
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(try editor.replaceImported(bytes))
        XCTAssertFalse(try editor.replaceImported(bytes))
        XCTAssertThrowsError(try editor.replaceImported(Data("{}".utf8)))
        let drums = try SequencerPatternArchive(drums: .init())
        XCTAssertThrowsError(try editor.replaceImported(drums.encoded())) {
            XCTAssertEqual($0 as? SequencerDraftEditor.EditError, .wrongKind)
        }
        XCTAssertEqual(editor.draft, other)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.undo())
    }

    func testUndoBoundAndMusicalNoOpIgnoreTransientIDs() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)]))
        var editor = try SequencerDraftEditor(draft: original)
        XCTAssertFalse(try editor.editNotes { _ in })
        XCTAssertFalse(editor.canUndo)
        for i in 1...20 {
            XCTAssertTrue(try editor.editNotes { $0.bpm = Double(120 + i) })
        }
        for i in (4..<20).reversed() {
            XCTAssertTrue(editor.undo())
            XCTAssertEqual(editor.draft.noteDraft()?.bpm, Double(120 + i))
        }
        XCTAssertFalse(editor.undo())
        XCTAssertEqual(editor.draft.noteDraft()?.bpm, 124)
    }

    func testShorteningRequiresExplicitDeletionAndGrooveNeedsSupportedGrid() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60), .init(index: 15, midi: nil)
        ]), groove: GrooveSettings())
        var editor = try SequencerDraftEditor(draft: original)
        XCTAssertThrowsError(try editor.editNotes { $0.length = 8 })
        XCTAssertThrowsError(try editor.editNotes { $0.stepsPerBeat = 8 })
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(try editor.editNotes {
            $0.steps.removeAll { $0.index >= 8 }
            $0.length = 8
        })
        XCTAssertTrue(try editor.setOptions(loop: false, groove: nil, channel: 4))
        XCTAssertTrue(try editor.editNotes { $0.stepsPerBeat = 8 })
        XCTAssertEqual(try editor.frozen().clip.length, 960)
        XCTAssertEqual(editor.draft.channel, 4)
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
    }

    func testRecordedContinuousAutomationIsNotSilentlyImported() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)]))
        var editor = try SequencerDraftEditor(draft: original)
        let bytes = try original.encoded()
        for key in ["automation", "relative", "reference", "feedback", "endpoint", "pitchBend"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object[key] = 64
            let modified = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try editor.replaceImported(modified), key)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
        notes[0]["cc74"] = 64
        object["notes"] = notes
        XCTAssertThrowsError(try editor.replaceImported(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testCombinedGridAndOptionsAreOneUndoTransaction() throws {
        let original = try SequencerPatternArchive(notes: .init(steps: [
            .init(index: 0, midi: 60), .init(index: 15, midi: nil)
        ]), groove: GrooveSettings())
        var editor = try SequencerDraftEditor(draft: original)
        let frozen = try editor.frozen()
        XCTAssertTrue(try editor.editNotesAndOptions { notes, options in
            notes.steps.removeAll { $0.index >= 8 }
            notes.length = 8
            notes.stepsPerBeat = 8
            notes.bpm = 100
            options.groove = nil
            options.channel = 5
            options.loop = true
        })
        let next = try editor.frozen()
        XCTAssertEqual(next.clip.length, 960)
        XCTAssertEqual(next.clip.bpm, 100)
        XCTAssertEqual(next.clip.notes.first?.channel, 5)
        XCTAssertTrue(next.loop)
        XCTAssertNil(editor.options.groove)
        XCTAssertEqual(frozen, try original.frozen())
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testCombinedInvalidOrThrowingChangesPreserveHistory() throws {
        enum Aborted: Error { case edit }
        let original = try SequencerPatternArchive(notes: .init(steps: [.init(index: 0, midi: 60)]),
                                                   groove: GrooveSettings())
        var editor = try SequencerDraftEditor(draft: original)
        XCTAssertTrue(try editor.editNotesAndOptions { notes, options in
            notes.bpm = 150
            options.loop = true
        })
        let before = editor.draft
        XCTAssertThrowsError(try editor.editNotesAndOptions { notes, options in
            notes.bpm = 90
            options.channel = nil
        }) {
            XCTAssertEqual($0 as? SequencerDraftEditor.EditError, .missingNoteChannel)
        }
        XCTAssertThrowsError(try editor.editNotesAndOptions { notes, options in
            notes.stepsPerBeat = 8
            options.channel = 3
        })
        XCTAssertThrowsError(try editor.editNotesAndOptions { notes, options in
            notes.bpm = 90
            options.loop = false
            throw Aborted.edit
        })
        XCTAssertEqual(editor.draft, before)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testCombinedDrumTransactionRejectsChannelAndWrongKind() throws {
        let original = try SequencerPatternArchive(drums: .init(hits: [
            .init(index: 0, voice: .kick), .init(index: 0, voice: .snare)
        ]))
        var editor = try SequencerDraftEditor(draft: original)
        XCTAssertTrue(try editor.editDrumsAndOptions { drums, options in
            drums.bpm = 200
            drums.hits[0].velocity = 0
            options.groove = GrooveSettings()
            options.loop = true
        })
        let before = editor.draft
        XCTAssertThrowsError(try editor.editDrumsAndOptions { drums, options in
            drums.hits.removeAll()
            options.channel = 9
        }) {
            XCTAssertEqual($0 as? SequencerDraftEditor.EditError, .drumChannel)
        }
        XCTAssertEqual(editor.draft, before)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(try editor.editDrumsAndOptions { _, _ in })
        XCTAssertFalse(editor.canUndo)
        XCTAssertThrowsError(try editor.editNotesAndOptions { _, _ in }) {
            XCTAssertEqual($0 as? SequencerDraftEditor.EditError, .wrongKind)
        }
    }
}
