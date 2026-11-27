import Foundation

/// Offline receipt adapter for a host-owned, serialized nominal scheduler.
/// A processed event is transport progress, not proof of audible DAW output.
/// The host must confirm only after successful ledger processing (or an
/// explicitly expired onset skip), and invalidate before cancelling/cleanup.
public struct SequencerScheduleProgress: Sendable {
    public enum Outcome: Sendable { case processed, skippedExpiredOnset }
    public struct Receipt: Equatable, Sendable {
        public let token: UUID
        public let sequence: UInt64
        public let cycle: UInt64
        public let tick: Int
    }
    public enum Result: Equatable, Sendable { case rejected, accepted, position(Receipt) }
    public let token: UUID
    public let schedule: MIDIClipSchedule
    public let loop: Bool
    public private(set) var cycle: UInt64 = 0
    public private(set) var nextIndex: Int = 0
    public private(set) var isClosed = false
    private var sequence: UInt64 = 0
    private var groupProcessed = false
    private var lastPublishedTick: Int?

    public init(token: UUID, take: FrozenSequencerPattern) throws {
        self.token = token
        schedule = try take.schedule()
        loop = take.loop
    }

    /// Index is the actual event index in this cycle, not a UI tick.
    /// No partial same-tick group publication; skipped-only groups do not
    /// generate positions. A final off at length is valid but not a grid tick.
    public mutating func confirmEvent(token: UUID, cycle: UInt64, index: Int,
                                      outcome: Outcome) -> Result {
        guard !isClosed, token == self.token, cycle == self.cycle,
              index == nextIndex, schedule.events.indices.contains(index) else { return .rejected }
        let event = schedule.events[index]
        if outcome == .skippedExpiredOnset && !event.isNoteOn { return .rejected }
        if outcome == .processed { groupProcessed = true }
        nextIndex += 1
        if nextIndex < schedule.events.count && schedule.events[nextIndex].tick == event.tick {
            return .accepted
        }
        let publish = groupProcessed && event.tick < schedule.length
        groupProcessed = false
        guard publish else { return .accepted }
        return publishPosition(tick: event.tick)
    }

    /// Host-confirmed position from its own monotonic scheduler clock, not
    /// an independent UI timer. Do not cross a due but unprocessed event,
    /// including a partially processed group at the requested tick.
    /// The host remains responsible for the clock-to-tick conversion and
    /// for confirming the actual cycle deadline before rollover.
    public mutating func confirmClock(token: UUID, cycle: UInt64, tick: Int) -> Result {
        guard !isClosed, token == self.token, cycle == self.cycle,
              (0..<schedule.length).contains(tick),
              lastPublishedTick.map({ tick > $0 }) ?? true,
              nextIndex == 0 || schedule.events[nextIndex - 1].tick <= tick,
              nextIndex == schedule.events.count || schedule.events[nextIndex].tick > tick
        else { return .rejected }
        return publishPosition(tick: tick)
    }

    private mutating func publishPosition(tick: Int) -> Result {
        guard lastPublishedTick.map({ tick > $0 }) ?? true else { return .rejected }
        guard sequence < UInt64.max else { isClosed = true; return .rejected }
        sequence += 1
        lastPublishedTick = tick
        return .position(.init(token: token, sequence: sequence, cycle: cycle, tick: tick))
    }

    /// Confirm only after the host reaches the cycle deadline, including
    /// trailing rest. Loop rollover never fabricates an event or a position.
    @discardableResult
    public mutating func confirmBoundary(token: UUID, cycle: UInt64) -> Bool {
        guard !isClosed, token == self.token, cycle == self.cycle,
              nextIndex == schedule.events.count else { return false }
        if !loop { isClosed = true; return true }
        guard cycle < UInt64.max else { isClosed = true; return false }
        self.cycle += 1
        nextIndex = 0
        lastPublishedTick = nil
        return true
    }

    public mutating func invalidate() { isClosed = true }
}
