import Foundation
import Testing
@testable import NoSpeakerCore

@Test(arguments: Array(0..<4))
func sequencerClockMatchesIndependentEventFrontier(mode: Int) throws {
    let loop = mode & 2 != 0
    let take = try mode & 1 == 0
        ? FrozenSequencerPattern(notes: .init(bpm: 120, length: 8, steps: [
            .init(index: 1, midi: 60, gate: 1), .init(index: 4, midi: 64, gate: 1)]), loop: loop)
        : FrozenSequencerPattern(drums: .init(bpm: 120, length: 8, hits: [
            .init(index: 1, voice: .kick), .init(index: 1, voice: .snare),
            .init(index: 4, voice: .kick)]), loop: loop)
    let schedule = try take.schedule()
    let events = schedule.events
    let onsets = events.indices.filter { events[$0].isNoteOn }
    let token = UUID()
    let foreign = UUID()
    for mask in 0..<(1 << onsets.count) {
        let skipped = Set(onsets.enumerated().compactMap { bit, index in
            mask & (1 << bit) != 0 ? index : nil
        })
        var progress = try SequencerScheduleProgress(token: token, take: take)
        var serial: UInt64 = 0
        for cycle in 0...(loop ? 1 : 0) {
            let current = UInt64(cycle)
            var published: Int? = nil
            for prefix in 0...events.count {
                // Independent frontier: all events at or before a clock tick
                // must be in the completed prefix, and none after it may be.
                for tick in -1...schedule.length {
                    let due = events.filter { $0.tick <= tick }.count
                    let elapsed = prefix == 0 || tick >= events[prefix - 1].tick
                    let allowed = tick >= 0 && tick < schedule.length && elapsed
                        && due == prefix && (published.map { tick > $0 } ?? true)
                    var probe = progress
                    let rejected = probe.confirmClock(token: foreign, cycle: current, tick: tick)
                    #expect(rejected == .rejected)
                    let result = probe.confirmClock(token: token, cycle: current, tick: tick)
                    if allowed {
                        guard case .position(let receipt) = result else {
                            Issue.record("Expected clock receipt at cycle \(cycle), prefix \(prefix), tick \(tick)")
                            continue
                        }
                        #expect(receipt.token == token && receipt.cycle == current)
                        #expect(receipt.tick == tick && receipt.sequence == serial + 1)
                        let duplicate = probe.confirmClock(token: token, cycle: current, tick: tick)
                        #expect(duplicate == .rejected)
                    } else {
                        #expect(result == .rejected)
                    }
                    #expect(probe.nextIndex == prefix && probe.cycle == current)
                }
                if prefix == events.count { break }
                let event = events[prefix]
                let outcome: SequencerScheduleProgress.Outcome = skipped.contains(prefix) ? .skippedExpiredOnset : .processed
                let result = progress.confirmEvent(token: token, cycle: current, index: prefix, outcome: outcome)
                let group = events.indices.filter { events[$0].tick == event.tick }
                let publishes = group.last == prefix && event.tick < schedule.length
                    && group.contains { !skipped.contains($0) }
                if publishes {
                    serial += 1
                    published = event.tick
                    guard case .position(let receipt) = result else {
                        Issue.record("Expected complete group receipt"); continue
                    }
                    #expect(receipt.sequence == serial && receipt.tick == event.tick && receipt.cycle == current)
                } else {
                    #expect(result == .accepted)
                }
            }
            let boundary = progress.confirmBoundary(token: token, cycle: current)
            #expect(boundary)
            let stale = progress.confirmClock(token: token, cycle: current, tick: 0)
            #expect(stale == .rejected)
        }
    }
}
