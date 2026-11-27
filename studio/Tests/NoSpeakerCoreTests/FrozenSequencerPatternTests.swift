import XCTest
@testable import NoSpeakerCore

final class FrozenSequencerPatternTests: XCTestCase {
    func testFrozenNotesPreserveTempoGateAndTrailingRests() throws {
        var draft = NoteSequence(bpm: 120, length: 16, steps: [
            .init(index: 0, midi: 60, velocity: 1, gate: 1),
            .init(index: 1, midi: 60, velocity: 0.5, gate: 0.5),
            .init(index: 15, midi: nil)
        ])
        let take = try FrozenSequencerPattern(notes: draft, loop: true)
        draft.bpm = 240
        draft.steps.removeAll()
        XCTAssertEqual(take.kind, .notes)
        XCTAssertTrue(take.loop)
        XCTAssertEqual(take.clip.bpm, 120)
        XCTAssertEqual(take.duration, 2, accuracy: 0.000001)
        XCTAssertEqual(take.clip.notes.map(\.duration), [240, 120])
        let schedule = try take.schedule()
        XCTAssertEqual(schedule.events.map(\.tick), [0, 240, 240, 360])
        XCTAssertEqual(schedule.events.map(\.isNoteOn), [true, false, true, false])
        XCTAssertEqual(schedule.length, 3840)
        XCTAssertEqual(take.gridStep(atConfirmedTick: 0), 0)
        XCTAssertEqual(take.gridStep(atConfirmedTick: 240), 1)
        XCTAssertEqual(take.gridStep(atConfirmedTick: 3839), 15)
        XCTAssertNil(take.gridStep(atConfirmedTick: 3840))
        XCTAssertNil(take.gridStep(atConfirmedTick: -1))
    }

    func testInvalidGridRejectedBeforeArithmetic() throws {
        for bpm in [Double.nan, .infinity, 0, 19, 301] {
            XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(bpm: bpm)))
        }
        for subdivision in [Int.min, 0, 7, Int.max] {
            XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(stepsPerBeat: subdivision)))
        }
        for length in [Int.min, 0, 4097, Int.max] {
            XCTAssertThrowsError(try FrozenSequencerPattern(drums: .init(length: length)))
        }
        XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(stepsPerBeat: 1, length: 4096)))
        XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(), channel: 16))
    }

    func testRejectInvalidRestMutedPitchAndDuplicateNotes() throws {
        let valid = NoteStep(index: 0, midi: 60)
        for bad in [
            NoteStep(index: -1, midi: nil),
            NoteStep(index: 1, midi: nil, velocity: .nan),
            NoteStep(index: 1, midi: 128, velocity: 0),
            NoteStep(index: 1, midi: 61, gate: .infinity),
            NoteStep(index: 1, midi: 61, gate: 0.01)
        ] {
            XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(steps: [valid, bad]))) {
                XCTAssertEqual($0 as? FrozenSequencerPattern.ValidationError, .invalidStep)
            }
        }
        XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(steps: [
            valid, .init(index: 0, midi: 64)
        ]))) {
            XCTAssertEqual($0 as? FrozenSequencerPattern.ValidationError, .duplicateStep)
        }
    }

    func testAllRestAndMutedPatternsDoNotAuthorizePlayback() throws {
        XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(steps: [
            .init(index: 0), .init(index: 1, midi: 60, velocity: 0)
        ]))) { XCTAssertEqual($0 as? MIDIClipError, .empty) }
        XCTAssertThrowsError(try FrozenSequencerPattern(drums: .init(hits: [
            .init(index: 0, voice: .kick, velocity: 0)
        ]))) { XCTAssertEqual($0 as? MIDIClipError, .empty) }
    }

    func testDrumSimultaneityCanonicalOrderAndChannelTen() throws {
        let hits: [DrumStep] = [
            .init(index: 0, voice: .snare),
            .init(index: 0, voice: .kick),
            .init(index: 15, voice: .tom)
        ]
        let take = try FrozenSequencerPattern(drums: .init(hits: hits))
        let reverse = try FrozenSequencerPattern(drums: .init(hits: Array(hits.reversed())))
        XCTAssertEqual(take, reverse)
        XCTAssertEqual(take.kind, .drums)
        XCTAssertEqual(take.clip.notes.map(\.pitch), [36, 38, 47])
        XCTAssertEqual(take.clip.notes.map(\.channel), [9, 9, 9])
        XCTAssertEqual(take.clip.notes.map(\.duration), [120, 120, 120])
        XCTAssertThrowsError(try FrozenSequencerPattern(drums: .init(hits: hits + [hits[0]]))) {
            XCTAssertEqual($0 as? FrozenSequencerPattern.ValidationError, .duplicateStep)
        }
        XCTAssertThrowsError(try FrozenSequencerPattern(drums: .init(hits: [
            .init(index: 16, voice: .kick)
        ])))
        XCTAssertThrowsError(try FrozenSequencerPattern(drums: .init(hits: [
            .init(index: 1, voice: .kick, velocity: .infinity)
        ])))
    }

    func testGrooveFrozenAndOnlySupportedGridAccepted() throws {
        let notes = (0..<16).map { NoteStep(index: $0, midi: 60, gate: 1) }
        var groove = GrooveSettings()
        groove.swing = 75
        groove.humanize = 100
        let a = try FrozenSequencerPattern(notes: .init(steps: notes), groove: groove)
        let b = try FrozenSequencerPattern(notes: .init(steps: Array(notes.reversed())), groove: groove)
        XCTAssertEqual(a, b)
        XCTAssertNoThrow(try a.clip.validated())
        for pair in zip(a.clip.notes, a.clip.notes.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.start + pair.0.duration, pair.1.start)
        }
        XCTAssertThrowsError(try FrozenSequencerPattern(notes: .init(stepsPerBeat: 8, steps: notes), groove: groove)) {
            XCTAssertEqual($0 as? FrozenSequencerPattern.ValidationError, .invalidGroove)
        }
    }

    func testBoundedPlaybackMatchesDeterministicEdgesIncludingTrailingRest() throws {
        let take = try FrozenSequencerPattern(notes: .init(steps: [
            .init(index: 0, midi: 60, gate: 1), .init(index: 1, midi: 60, gate: 1)
        ]))
        var playback = try BoundedMIDIPlayback(clip: take.clip)
        let expected = playback.events.map(\.command)
        var sent: [SensorCommand] = []
        XCTAssertTrue(try playback.begin(now: 1000))
        for _ in 0...expected.count {
            guard let deadline = playback.nextDeadline else { break }
            playback.advance(now: deadline, send: { sent.append($0); return true })
        }
        XCTAssertEqual(sent, expected)
        XCTAssertEqual(playback.state, .finished)
        XCTAssertTrue(playback.outstanding.isEmpty)
        XCTAssertEqual(playback.durationNS, 2_000_000_000)
    }

    func testCancelBetweenSimultaneousHitsRetainsOnlyAttemptedDebt() throws {
        let take = try FrozenSequencerPattern(drums: .init(hits: [
            .init(index: 0, voice: .kick), .init(index: 0, voice: .snare)
        ]))
        var playback = try BoundedMIDIPlayback(clip: take.clip)
        XCTAssertTrue(try playback.begin(now: 0))
        var sent: [SensorCommand] = []
        var cancel = false
        playback.advance(now: 0, refreshNow: { 0 }, shouldStop: { cancel }, send: {
            sent.append($0)
            if $0.value > 0 { cancel = true; return true }
            return false
        })
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertEqual(sent.map { $0.destination.number }, [36, 36])
        XCTAssertEqual(sent.map { $0.value > 0 }, [true, false])
        XCTAssertEqual(playback.outstanding.count, 1)
        playback.advance(now: 125_000_000, send: { sent.append($0); return true })
        XCTAssertEqual(sent.count, 2)
        playback.retryCleanup(send: { sent.append($0); return true })
        XCTAssertTrue(playback.outstanding.isEmpty)
        XCTAssertEqual(sent.map { $0.destination.number }, [36, 36, 36])
    }

    func testComposerObservedEditAndRevertInvalidatesProposalAndUndo() {
        var draft = ComposerDraft<[Int?]>()
        let a: [Int?] = [60, nil]
        let b: [Int?] = [62, nil]
        let c: [Int?] = [64, nil]
        draft.preview(current: a, candidate: b)
        XCTAssertEqual(draft.apply(current: a), b)
        XCTAssertFalse(draft.observe(current: b))
        draft.preview(current: b, candidate: c)
        XCTAssertTrue(draft.observe(current: a))
        XCTAssertFalse(draft.observe(current: b))
        XCTAssertFalse(draft.canApply(current: b))
        XCTAssertFalse(draft.canUndo(current: b))
        XCTAssertNil(draft.apply(current: b))
        XCTAssertNil(draft.undo(current: b))
    }

    func testComposerUndoHistoryBoundAndInternalObservations() {
        var draft = ComposerDraft<Set<String>>()
        var current: Set<String> = []
        for i in 0..<20 {
            let next: Set<String> = ["kick:\(i)"]
            draft.preview(current: current, candidate: next)
            guard let applied = draft.apply(current: current) else { return XCTFail("apply failed") }
            current = applied
            XCTAssertFalse(draft.observe(current: current))
        }
        var undos = 0
        while let previous = draft.undo(current: current) {
            current = previous
            undos += 1
            XCTAssertFalse(draft.observe(current: current))
        }
        XCTAssertEqual(undos, 16)
        XCTAssertEqual(current, ["kick:3"])
    }
}
