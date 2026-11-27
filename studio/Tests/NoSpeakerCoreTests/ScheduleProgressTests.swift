import Foundation
import XCTest
@testable import NoSpeakerCore

final class ScheduleProgressTests: XCTestCase {
    private func take(loop: Bool) throws -> FrozenSequencerPattern {
        try FrozenSequencerPattern(drums: .init(bpm: 120, length: 8, hits: [
            .init(index: 0, voice: .kick), .init(index: 0, voice: .snare),
            .init(index: 4, voice: .kick)]), loop: loop)
    }
    func testCompleteGroupAndTokenOrdering() throws {
        let t = try take(loop: true), id = UUID()
        var p = try SequencerScheduleProgress(token: id, take: t)
        XCTAssertEqual(p.schedule.events[0].tick, p.schedule.events[1].tick)
        XCTAssertEqual(p.confirmEvent(token: UUID(), cycle: 0, index: 0, outcome: .processed), .rejected)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .processed), .rejected)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .processed), .accepted)
        XCTAssertFalse(p.confirmBoundary(token: id, cycle: 0))
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .processed), .rejected)
        guard case .position(let r) = p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .processed) else { return XCTFail("group not published") }
        XCTAssertEqual(r.tick, 0); XCTAssertEqual(r.sequence, 1); XCTAssertEqual(r.token, id)
    }
    func testSkippedOnlyAndInvalidOffSkip() throws {
        let id = UUID(); var p = try SequencerScheduleProgress(token: id, take: take(loop: false))
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .skippedExpiredOnset), .accepted)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .skippedExpiredOnset), .accepted)
        XCTAssertFalse(p.schedule.events[2].isNoteOn)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 2, outcome: .skippedExpiredOnset), .rejected)
        XCTAssertEqual(p.nextIndex, 2)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 2, outcome: .processed), .accepted)
        guard case .position(let r) = p.confirmEvent(token: id, cycle: 0, index: 3, outcome: .processed) else { return XCTFail("off group") }
        XCTAssertEqual(r.sequence, 1)
    }
    func testLoopAndPresentationBridge() throws {
        let t = try take(loop: true); var display = SequencerTakePresentation()
        let id = try XCTUnwrap(display.reserve(t)); XCTAssertTrue(display.confirmStarted(token: id))
        var p = try SequencerScheduleProgress(token: id, take: t)
        var previous: UInt64 = 0
        for cycle: UInt64 in 0...2 {
            XCTAssertFalse(p.confirmBoundary(token: id, cycle: cycle))
            for i in p.schedule.events.indices {
                let event = p.schedule.events[i]
                let r = p.confirmEvent(token: id, cycle: cycle, index: i, outcome: .processed)
                if case .position(let receipt) = r {
                    XCTAssertGreaterThan(receipt.sequence, previous); previous = receipt.sequence
                    XCTAssertEqual(receipt.tick, event.tick)
                    XCTAssertTrue(display.confirmPosition(token: receipt.token, receipt: receipt.sequence, cycle: receipt.cycle, tick: receipt.tick))
                } else { XCTAssertEqual(r, .accepted) }
            }
            XCTAssertTrue(p.confirmBoundary(token: id, cycle: cycle))
            XCTAssertEqual(p.confirmEvent(token: id, cycle: cycle, index: 0, outcome: .processed), .rejected)
            XCTAssertEqual(display.position?.cycle, cycle)
        }
        p.invalidate(); XCTAssertTrue(display.requestStop(token: id))
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 3, index: 0, outcome: .processed), .rejected)
        XCTAssertFalse(p.confirmBoundary(token: id, cycle: 3))
        XCTAssertTrue(display.stopped(token: id, cleanupConfirmed: false)); XCTAssertNil(display.reserve(t))
    }
    func testTerminalOffAndNonLoopBoundary() throws {
        let t = try FrozenSequencerPattern(notes: .init(bpm: 120, length: 1, steps: [.init(index: 0, midi: 60, gate: 1)]))
        let id = UUID(); var p = try SequencerScheduleProgress(token: id, take: t)
        guard case .position = p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .processed) else { return XCTFail("onset") }
        XCTAssertEqual(p.schedule.events[1].tick, p.schedule.length)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .processed), .accepted)
        XCTAssertTrue(p.confirmBoundary(token: id, cycle: 0)); XCTAssertTrue(p.isClosed)
        XCTAssertFalse(p.confirmBoundary(token: id, cycle: 0))
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .processed), .rejected)
    }

    func testClockCannotCrossUnprocessedOrPartialGroup() throws {
        let id = UUID(); var p = try SequencerScheduleProgress(token: id, take: take(loop: true))
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: 0), .rejected)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .processed), .accepted)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: 1), .rejected)
        guard case .position(let onset) = p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .processed) else { return XCTFail("group") }
        let next = p.schedule.events[2].tick
        XCTAssertGreaterThan(next, 1)
        guard case .position(let clock) = p.confirmClock(token: id, cycle: 0, tick: next - 1) else { return XCTFail("clock") }
        XCTAssertEqual(clock.sequence, onset.sequence + 1)
        XCTAssertEqual(clock.tick, next - 1)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: next - 1), .rejected)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: next - 2), .rejected)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: next), .rejected)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 2, outcome: .processed), .accepted)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: next), .rejected)
        guard case .position(let off) = p.confirmEvent(token: id, cycle: 0, index: 3, outcome: .processed) else { return XCTFail("off group") }
        XCTAssertEqual(off.sequence, clock.sequence + 1)
        XCTAssertEqual(off.tick, next)
    }

    func testClockLeadingTrailingRestAndRollover() throws {
        let t = try FrozenSequencerPattern(notes: .init(bpm: 120, length: 8, steps: [.init(index: 4, midi: 60, gate: 0.5)]), loop: true)
        var display = SequencerTakePresentation()
        let id = try XCTUnwrap(display.reserve(t)); XCTAssertTrue(display.confirmStarted(token: id))
        var p = try SequencerScheduleProgress(token: id, take: t)
        var last: UInt64 = 0
        for cycle: UInt64 in 0...1 {
            let leading = p.schedule.events[0].tick - 1
            guard case .position(let first) = p.confirmClock(token: id, cycle: cycle, tick: leading) else { return XCTFail("leading rest") }
            XCTAssertEqual(first.sequence, last + 1); last = first.sequence
            XCTAssertTrue(display.confirmPosition(token: id, receipt: first.sequence, cycle: first.cycle, tick: first.tick))
            XCTAssertEqual(p.confirmClock(token: UUID(), cycle: cycle, tick: leading+1), .rejected)
            for i in p.schedule.events.indices {
                guard case .position(let r) = p.confirmEvent(token: id, cycle: cycle, index: i, outcome: .processed) else { return XCTFail("event") }
                XCTAssertEqual(r.sequence, last+1); last = r.sequence
                XCTAssertTrue(display.confirmPosition(token: id, receipt: r.sequence, cycle: r.cycle, tick: r.tick))
            }
            let tail = p.schedule.length - 1
            guard case .position(let trailing) = p.confirmClock(token: id, cycle: cycle, tick: tail) else { return XCTFail("trailing rest") }
            XCTAssertEqual(trailing.sequence, last+1); last = trailing.sequence
            XCTAssertTrue(display.confirmPosition(token: id, receipt: trailing.sequence, cycle: trailing.cycle, tick: trailing.tick))
            XCTAssertEqual(display.position?.gridStep, 7)
            XCTAssertEqual(p.confirmClock(token: id, cycle: cycle, tick: p.schedule.length), .rejected)
            XCTAssertTrue(p.confirmBoundary(token: id, cycle: cycle))
            XCTAssertEqual(p.confirmClock(token: id, cycle: cycle, tick: 0), .rejected)
        }
        p.invalidate()
        XCTAssertEqual(p.confirmClock(token: id, cycle: 2, tick: 0), .rejected)
    }

    func testClockAfterSkippedGroupAndTerminalOff() throws {
        let t = try FrozenSequencerPattern(notes: .init(bpm: 120, length: 1, steps: [.init(index: 0, midi: 60, gate: 1)]))
        let id = UUID(); var p = try SequencerScheduleProgress(token: id, take: t)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .skippedExpiredOnset), .accepted)
        guard case .position(let r) = p.confirmClock(token: id, cycle: 0, tick: p.schedule.length - 1) else { return XCTFail("clock after skip") }
        XCTAssertEqual(r.sequence, 1)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: -1), .rejected)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 1, tick: 0), .rejected)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 1, outcome: .processed), .accepted)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: p.schedule.length), .rejected)
        XCTAssertTrue(p.confirmBoundary(token: id, cycle: 0))
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: 0), .rejected)
    }

    func testClockCannotRewindBehindSkippedEvent() throws {
        let t = try FrozenSequencerPattern(notes: .init(bpm: 120, length: 8, steps: [.init(index: 4, midi: 60, gate: 0.5)]))
        let id = UUID(); var p = try SequencerScheduleProgress(token: id, take: t)
        let onset = p.schedule.events[0].tick
        XCTAssertGreaterThan(onset, 0)
        XCTAssertEqual(p.confirmEvent(token: id, cycle: 0, index: 0, outcome: .skippedExpiredOnset), .accepted)
        XCTAssertEqual(p.confirmClock(token: id, cycle: 0, tick: onset - 1), .rejected)
        guard case .position(let r) = p.confirmClock(token: id, cycle: 0, tick: onset) else { return XCTFail("confirmed elapsed position") }
        XCTAssertEqual(r.tick, onset)
    }

}
