import Foundation
import Testing
@testable import NoSpeakerCore

private func check(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}

@Test(arguments: Array(0..<16))
func sequencerRetirementRejectsDelayedReceiptsAtEveryEventBoundary(mask: Int) throws {
    let drums = mask & 1 != 0
    let loop = mask & 2 != 0
    let dirty = mask & 4 != 0
    let skipOnsets = mask & 8 != 0
    let take = try drums
        ? FrozenSequencerPattern(drums: .init(bpm: 120, length: 8, hits: [
            .init(index: 1, voice: .kick), .init(index: 1, voice: .snare),
            .init(index: 4, voice: .kick)]), loop: loop)
        : FrozenSequencerPattern(notes: .init(bpm: 120, length: 8, steps: [
            .init(index: 1, midi: 60, gate: 1), .init(index: 4, midi: 64, gate: 1)]), loop: loop)
    let schedule = try take.schedule()
    for completedCycles in 0...(loop ? 2 : 0) {
        for cut in 0...schedule.events.count {
            var display = SequencerTakePresentation()
            let reserved = display.reserve(take)
            let token = try #require(reserved)
            check(display.confirmStarted(token: token))
            var progress = try SequencerScheduleProgress(token: token, take: take)
            var held: [SequencerScheduleProgress.Receipt] = []
            for cycle in 0...completedCycles {
                let current = UInt64(cycle)
                let count = cycle == completedCycles ? cut : schedule.events.count
                let leading = progress.confirmClock(token: token, cycle: current, tick: 0)
                guard case .position(let receipt) = leading else {
                    Issue.record("Leading rest must produce a receipt"); return
                }
                held.append(receipt)
                for index in 0..<count {
                    let outcome: SequencerScheduleProgress.Outcome = skipOnsets && schedule.events[index].isNoteOn
                        ? .skippedExpiredOnset : .processed
                    let result = progress.confirmEvent(token: token, cycle: current, index: index, outcome: outcome)
                    check(result != .rejected)
                    if case .position(let position) = result { held.append(position) }
                }
                if cycle < completedCycles {
                    check(progress.confirmBoundary(token: token, cycle: current))
                }
            }
            // Keep the newest valid receipt undelivered until after Stop.
            let latest = try #require(held.last)
            for receipt in held.dropLast() {
                check(display.confirmPosition(token: receipt.token, receipt: receipt.sequence,
                                                cycle: receipt.cycle, tick: receipt.tick))
            }
            check(display.requestStop(token: token))
            progress.invalidate()
            let index = progress.nextIndex
            let cycle = progress.cycle
            check(progress.confirmEvent(token: token, cycle: cycle, index: index, outcome: .processed) == .rejected)
            check(progress.confirmClock(token: token, cycle: cycle, tick: schedule.length - 1) == .rejected)
            check(!progress.confirmBoundary(token: token, cycle: cycle))
            check(progress.nextIndex == index && progress.cycle == cycle)
            check(!display.confirmPosition(token: latest.token, receipt: latest.sequence, cycle: latest.cycle, tick: latest.tick))
            check(display.position == nil)
            check(display.stopped(token: token, cleanupConfirmed: !dirty))
            if dirty {
                check(display.reserve(take) == nil)
                check(!display.confirmCleanup(token: UUID(), succeeded: true))
                check(!display.confirmCleanup(token: token, succeeded: false))
                check(!display.permitsMIDIStart(running: false, cleanupPending: true))
                check(display.confirmCleanup(token: token, succeeded: true))
            }
            let next = display.reserve(take)
            let replacement = try #require(next)
            check(replacement != token)
            check(!display.confirmStarted(token: token))
            check(display.confirmStarted(token: replacement))
            check(!display.stopped(token: token, cleanupConfirmed: true))
            check(!display.confirmCleanup(token: token, succeeded: true))
            for receipt in held.reversed() {
                check(!display.confirmPosition(token: receipt.token, receipt: receipt.sequence,
                                                 cycle: receipt.cycle, tick: receipt.tick))
            }
            check(display.position == nil)
            var fresh = try SequencerScheduleProgress(token: replacement, take: take)
            guard case .position(let first) = fresh.confirmClock(token: replacement, cycle: 0, tick: 0) else {
                Issue.record("Replacement must have its own receipt sequence"); return
            }
            check(first.sequence == 1)
            check(display.confirmPosition(token: first.token, receipt: first.sequence, cycle: first.cycle, tick: first.tick))
            check(display.confirmedGridStep(for: take.kind) == 0)
            check(display.stopped(token: replacement, cleanupConfirmed: true))
        }
    }
}
