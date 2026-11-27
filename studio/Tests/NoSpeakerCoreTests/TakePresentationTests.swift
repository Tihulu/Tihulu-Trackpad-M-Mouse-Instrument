import Foundation
import XCTest
@testable import NoSpeakerCore

final class TakePresentationTests: XCTestCase {
    private func take(loop: Bool) throws -> FrozenSequencerPattern {
        try FrozenSequencerPattern(notes: .init(bpm: 120, length: 8, steps: [.init(index: 0, midi: 60)]), loop: loop)
    }
    private func start(_ p: inout SequencerTakePresentation, _ t: FrozenSequencerPattern) -> UUID? {
        guard let token = p.reserve(t) else { return nil }
        XCTAssertTrue(p.confirmStarted(token: token))
        return token
    }
    func testNoSyntheticPositionAndMonotonicReceipt() throws {
        var p = SequencerTakePresentation()
        let t = try take(loop: true)
        let a = try XCTUnwrap(start(&p, t))
        XCTAssertEqual(p.phase, .playing); XCTAssertNil(p.position)
        XCTAssertNil(start(&p, t))
        XCTAssertFalse(p.confirmPosition(token: UUID(), receipt: 999, cycle: 0, tick: 0))
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 240))
        XCTAssertEqual(p.position?.gridStep, 1)
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 2, cycle: 0, tick: 239))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 2, cycle: 0, tick: 480))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 480))
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 3, cycle: 0, tick: 480))
        XCTAssertEqual(p.position?.gridStep, 2)
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 4, cycle: 2, tick: 0))
        XCTAssertEqual(p.position?.cycle, 2)
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 5, cycle: 1, tick: t.clip.length - 1))
        XCTAssertEqual(p.position?.tick, 0)
    }
    func testNonLoopAndInvalidBoundaries() throws {
        var p = SequencerTakePresentation()
        let t = try take(loop: false)
        let a = try XCTUnwrap(start(&p, t))
        for (i,tick) in [Int.min,-1,t.clip.length,Int.max].enumerated() {
            XCTAssertFalse(p.confirmPosition(token: a, receipt: UInt64(i), cycle: 0, tick: tick))
            XCTAssertNil(p.position)
        }
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 4, cycle: 1, tick: 0))
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 5, cycle: 0, tick: t.clip.length-1))
        XCTAssertEqual(p.position?.gridStep, 7)
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 6, cycle: 1, tick: 0))
        XCTAssertEqual(p.position?.gridStep, 7)
    }
    func testCleanupAndStaleCallbacks() throws {
        var p = SequencerTakePresentation()
        let t = try take(loop: true)
        let a = try XCTUnwrap(start(&p, t))
        XCTAssertFalse(p.stopped(token: UUID(), cleanupConfirmed: true))
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 0))
        XCTAssertTrue(p.stopped(token: a, cleanupConfirmed: false))
        XCTAssertEqual(p.phase, .cleanupPending); XCTAssertEqual(p.take, t); XCTAssertNil(p.position)
        XCTAssertNil(start(&p, t))
        XCTAssertFalse(p.stopped(token: a, cleanupConfirmed: true))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 2, cycle: 1, tick: 0))
        XCTAssertFalse(p.confirmCleanup(token: UUID(), succeeded: true))
        XCTAssertFalse(p.confirmCleanup(token: a, succeeded: false))
        XCTAssertTrue(p.confirmCleanup(token: a, succeeded: true))
        XCTAssertEqual(p.phase, .idle); XCTAssertNil(p.take); XCTAssertNil(p.token)
        let b = try XCTUnwrap(start(&p, t)); XCTAssertNotEqual(a,b)
        XCTAssertFalse(p.stopped(token: a, cleanupConfirmed: true))
        XCTAssertFalse(p.confirmCleanup(token: a, succeeded: true))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: UInt64.max, cycle: 1, tick: 0))
        XCTAssertTrue(p.confirmPosition(token: b, receipt: 0, cycle: 0, tick: 0))
        XCTAssertTrue(p.stopped(token: b, cleanupConfirmed: true))
        XCTAssertEqual(p.phase, .idle)
    }
    func testDraftMutationDoesNotRewritePresentation() throws {
        let archive = try SequencerPatternArchive(notes: .init(bpm: 120, length: 8, steps: [.init(index: 0, midi: 60)]), channel: 2, loop: true)
        var editor = try SequencerDraftEditor(draft: archive)
        var p = SequencerTakePresentation()
        let original = try editor.frozen()
        let a = try XCTUnwrap(start(&p, original))
        XCTAssertTrue(try editor.editNotes { $0.bpm = 90; $0.length = 4; $0.stepsPerBeat = 2 })
        XCTAssertNotEqual(try editor.frozen(), original)
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 240))
        XCTAssertEqual(p.position?.gridStep, 1); XCTAssertEqual(p.take, original)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(p.take, original)
    }
    func testReservationAndFailedStartupRetainCleanup() throws {
        var p = SequencerTakePresentation()
        let t = try take(loop: true)
        let a = try XCTUnwrap(p.reserve(t))
        XCTAssertEqual(p.phase, .starting)
        XCTAssertNil(p.position)
        XCTAssertNil(p.reserve(t))
        XCTAssertFalse(p.confirmStarted(token: UUID()))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 0))
        XCTAssertTrue(p.stopped(token: a, cleanupConfirmed: false))
        XCTAssertEqual(p.phase, .cleanupPending)
        XCTAssertFalse(p.confirmStarted(token: a))
        XCTAssertNil(p.reserve(t))
        XCTAssertFalse(p.confirmCleanup(token: a, succeeded: false))
        XCTAssertTrue(p.confirmCleanup(token: a, succeeded: true))
        let b = try XCTUnwrap(p.reserve(t))
        XCTAssertFalse(p.confirmStarted(token: a))
        XCTAssertFalse(p.stopped(token: a, cleanupConfirmed: true))
        XCTAssertTrue(p.confirmStarted(token: b))
        XCTAssertTrue(p.confirmPosition(token: b, receipt: 0, cycle: 0, tick: 0))
    }
    func testGridMarkerUsesOnlyMatchingConfirmedPlayingTake() throws {
        var p = SequencerTakePresentation()
        let notes = try take(loop: true)
        let drums = try FrozenSequencerPattern(drums: .init(bpm: 120, length: 8,
            hits: [.init(index: 0, voice: .kick)]), loop: true)
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertNil(p.confirmedGridStep(for: .drums))
        let a = try XCTUnwrap(p.reserve(notes))
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertTrue(p.confirmStarted(token: a))
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertTrue(p.confirmPosition(token: a, receipt: 1, cycle: 0, tick: 240))
        XCTAssertEqual(p.confirmedGridStep(for: .notes), 1)
        XCTAssertNil(p.confirmedGridStep(for: .drums))
        XCTAssertTrue(p.requestStop(token: a))
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertTrue(p.stopped(token: a, cleanupConfirmed: false))
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertNil(p.reserve(drums))
        XCTAssertTrue(p.confirmCleanup(token: a, succeeded: true))
        let b = try XCTUnwrap(start(&p, drums))
        XCTAssertFalse(p.confirmPosition(token: a, receipt: 2, cycle: 0, tick: 480))
        XCTAssertNil(p.confirmedGridStep(for: .drums))
        XCTAssertTrue(p.confirmPosition(token: b, receipt: 1, cycle: 0, tick: 480))
        XCTAssertEqual(p.confirmedGridStep(for: .drums), 2)
        XCTAssertNil(p.confirmedGridStep(for: .notes))
        XCTAssertTrue(p.confirmPosition(token: b, receipt: 2, cycle: 1, tick: 0))
        XCTAssertEqual(p.confirmedGridStep(for: .drums), 0)
        XCTAssertTrue(p.stopped(token: b, cleanupConfirmed: true))
        XCTAssertNil(p.confirmedGridStep(for: .drums))
    }

    func testMIDIControlsRemainAvailableWithoutNominalTake() throws {
        var p = SequencerTakePresentation()
        for running in [false, true] {
            for cleanup in [false, true] {
                XCTAssertEqual(p.permitsMIDIStart(running: running, cleanupPending: cleanup), !running && !cleanup)
                XCTAssertEqual(p.needsMIDIStopControl(running: running, cleanupPending: cleanup), running || cleanup)
            }
        }
        let t = try take(loop: true)
        let token = try XCTUnwrap(p.reserve(t))
        func assertBlocked(_ state: SequencerTakePresentation) {
            for running in [false, true] {
                for cleanup in [false, true] {
                    XCTAssertFalse(state.permitsMIDIStart(running: running, cleanupPending: cleanup))
                    XCTAssertTrue(state.needsMIDIStopControl(running: running, cleanupPending: cleanup))
                }
            }
        }
        assertBlocked(p)
        XCTAssertTrue(p.confirmStarted(token: token)); assertBlocked(p)
        XCTAssertTrue(p.requestStop(token: token)); assertBlocked(p)
        XCTAssertTrue(p.stopped(token: token, cleanupConfirmed: false)); assertBlocked(p)
        XCTAssertTrue(p.confirmCleanup(token: token, succeeded: true))
        XCTAssertTrue(p.permitsMIDIStart(running: false, cleanupPending: false))
        XCTAssertFalse(p.needsMIDIStopControl(running: false, cleanupPending: false))
    }

    func testStopDuringStartupCannotResurrect() throws {
        var p = SequencerTakePresentation()
        let t = try take(loop: false)
        let a = try XCTUnwrap(p.reserve(t))
        XCTAssertFalse(p.requestStop(token: UUID()))
        XCTAssertTrue(p.requestStop(token: a))
        XCTAssertEqual(p.phase, .stopping)
        XCTAssertFalse(p.confirmStarted(token: a))
        XCTAssertFalse(p.requestStop(token: a))
        XCTAssertNil(p.reserve(t))
        XCTAssertFalse(p.confirmCleanup(token: a, succeeded: true))
        XCTAssertTrue(p.stopped(token: a, cleanupConfirmed: true))
        let b = try XCTUnwrap(p.reserve(t))
        XCTAssertFalse(p.requestStop(token: a))
        XCTAssertTrue(p.confirmStarted(token: b))
        XCTAssertTrue(p.confirmPosition(token: b, receipt: 1, cycle: 0, tick: 240))
        XCTAssertTrue(p.requestStop(token: b))
        XCTAssertNil(p.position)
        XCTAssertFalse(p.confirmPosition(token: b, receipt: 2, cycle: 0, tick: 480))
        XCTAssertTrue(p.stopped(token: b, cleanupConfirmed: false))
        XCTAssertFalse(p.confirmCleanup(token: a, succeeded: true))
        XCTAssertTrue(p.confirmCleanup(token: b, succeeded: true))
        XCTAssertEqual(p.phase, .idle)
    }
}
