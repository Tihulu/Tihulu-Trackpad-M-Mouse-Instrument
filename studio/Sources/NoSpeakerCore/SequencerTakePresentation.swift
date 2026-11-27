import Foundation

/// Presentation-only state for a host-owned transport. A successful start,
/// a confirmed scheduler position, and confirmed cleanup are host evidence,
/// not operations performed by this value. Serialize calls with the transport.
public struct SequencerTakePresentation: Sendable {
    public enum Phase: Equatable, Sendable { case idle, starting, playing, stopping, cleanupPending }
    public struct Position: Equatable, Sendable {
        public let cycle: UInt64
        public let tick: Int
        public let gridStep: Int
    }
    public private(set) var phase: Phase = .idle
    public private(set) var token: UUID?
    public private(set) var take: FrozenSequencerPattern?
    public private(set) var position: Position?
    private var lastReceipt: UInt64?
    public init() {}

    /// Reserve identity before any host operation that may emit output.
    /// The serialized host must check this result before opening or configuring
    /// a transport. A reservation is not proof of playback.
    public mutating func reserve(_ take: FrozenSequencerPattern) -> UUID? {
        guard phase == .idle else { return nil }
        let token = UUID()
        self.token = token
        self.take = take
        position = nil
        lastReceipt = nil
        phase = .starting
        return token
    }

    /// A delayed start confirmation cannot resurrect a cancelled reservation.
    @discardableResult
    public mutating func confirmStarted(token: UUID) -> Bool {
        guard phase == .starting, self.token == token else { return false }
        phase = .playing
        return true
    }

    /// Invalidate position/start admission immediately, before cancellation or
    /// cleanup. The host must still retire its own task and all owned outputs.
    @discardableResult
    public mutating func requestStop(token: UUID) -> Bool {
        guard self.token == token, phase == .starting || phase == .playing else { return false }
        phase = .stopping
        position = nil
        return true
    }

    /// Host supplies an increasing publication receipt and a confirmed tick
    /// inside a cycle. Skipped ticks/cycles are allowed, not synthesized.
    /// Non-looping takes never accept a cycle other than zero.
    @discardableResult
    public mutating func confirmPosition(token: UUID, receipt: UInt64,
                                         cycle: UInt64, tick: Int) -> Bool {
        guard phase == .playing, self.token == token, let take,
              lastReceipt.map({ receipt > $0 }) ?? true else { return false }
        // Consume an advancing receipt even if its payload is invalid, so a
        // delayed earlier publication cannot subsequently move the display.
        lastReceipt = receipt
        guard take.loop || cycle == 0,
              let step = take.gridStep(atConfirmedTick: tick) else { return false }
        if let prior = position {
            guard cycle > prior.cycle || (cycle == prior.cycle && tick >= prior.tick) else { return false }
        }
        position = .init(cycle: cycle, tick: tick, gridStep: step)
        return true
    }

    /// A grid may display only its own active take's confirmed position.
    /// Draft cells may have changed; this is transport location, not note activity.
    public func confirmedGridStep(for kind: FrozenSequencerPattern.Kind) -> Int? {
        guard phase == .playing, take?.kind == kind else { return nil }
        return position?.gridStep
    }

    /// The nominal take is not the only MIDI path. Legacy/tuned playback
    /// and failed endpoint cleanup remain authoritative even without a take.
    public func permitsMIDIStart(running: Bool, cleanupPending: Bool) -> Bool {
        phase == .idle && !running && !cleanupPending
    }

    public func needsMIDIStopControl(running: Bool, cleanupPending: Bool) -> Bool {
        phase != .idle || running || cleanupPending
    }

    /// Report terminal host evidence after startup failure, cancellation or
    /// natural end. No worker may still start or send notes under this token.
    /// Keep the take until matching cleanup succeeds.
    @discardableResult
    public mutating func stopped(token: UUID, cleanupConfirmed: Bool) -> Bool {
        guard self.token == token, phase == .starting || phase == .playing || phase == .stopping else { return false }
        position = nil
        if cleanupConfirmed { reset() } else { phase = .cleanupPending }
        return true
    }

    /// A failed cleanup attempt leaves the presentation pending. Do not call
    /// with success based on a timer, UI action or an unrelated endpoint.
    @discardableResult
    public mutating func confirmCleanup(token: UUID, succeeded: Bool) -> Bool {
        guard phase == .cleanupPending, self.token == token, succeeded else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        phase = .idle
        token = nil
        take = nil
        position = nil
        lastReceipt = nil
    }
}
