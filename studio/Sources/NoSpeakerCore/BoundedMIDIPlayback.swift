import Foundation

/// One-shot nominal note playback, using a caller-owned isolated sink.
/// No device access, background worker, future timestamp sends or global panic.
/// The caller serializes advance/stop, supplies monotonic uptime and retains
/// the sink until outstanding cleanup has been confirmed.
public struct BoundedMIDIPlayback: Sendable {
    public enum Failure: Error, Equatable {
        case capacity, clockOverflow
    }
    public enum State: String, Sendable {
        case ready, playing, finished, stopped, faulted
    }
    public struct Event: Equatable, Sendable {
        public let offsetNS: UInt64
        public let command: SensorCommand
    }
    public static let maximumDurationNS: UInt64 = 10_000_000_000
    public static let maximumNotes = 256
    public static let maximumLatenessNS: UInt64 = 50_000_000
    public let events: [Event]
    public let durationNS: UInt64
    public private(set) var state: State = .ready
    public private(set) var outstanding: Set<SensorDestination> = []
    private var start: UInt64 = 0
    private var last: UInt64 = 0
    private var next = 0

    public init(clip input: MIDIClip) throws {
        let clip = try input.validated()
        let nanosPerTick = 60_000_000_000 / clip.bpm / Double(MIDIClip.ppq)
        let duration = Double(clip.length) * nanosPerTick
        guard clip.notes.count <= Self.maximumNotes,
              duration <= Double(Self.maximumDurationNS) else { throw Failure.capacity }
        durationNS = UInt64(duration.rounded())
        events = clip.notes.flatMap { n -> [Event] in
            let target = SensorDestination(.note, channel:n.channel, number:n.pitch)
            return [
                .init(offsetNS:UInt64((Double(n.start)*nanosPerTick).rounded()),command:.init(target,value:n.velocity)),
                .init(offsetNS:UInt64((Double(n.start+n.duration)*nanosPerTick).rounded()),command:.init(target,value:0))
            ]
        }.sorted { a,b in
            if a.offsetNS != b.offsetNS { return a.offsetNS < b.offsetNS }
            if (a.command.value == 0) != (b.command.value == 0) { return a.command.value == 0 }
            if a.command.destination.channel != b.command.destination.channel {
                return a.command.destination.channel < b.command.destination.channel
            }
            return a.command.destination.number < b.command.destination.number
        }
    }

    /// Begin once. No sends until the caller explicitly advances.
    public mutating func begin(now: UInt64) throws -> Bool {
        guard state == .ready else { return false }
        guard now <= UInt64.max - durationNS else {
            state = .faulted
            throw Failure.clockOverflow
        }
        start = now
        last = now
        state = .playing
        return true
    }

    /// A driver should wait for this deadline instead of busy spinning.
    public var nextDeadline: UInt64? {
        guard state == .playing else { return nil }
        return start + (next < events.count ? events[next].offsetNS : durationNS)
    }

    /// Never replay stale onsets after a stalled scheduler. Failed sends are
    /// ambiguous: record attempted onsets before sending and retain failed offs.
    public mutating func advance(now: UInt64, send: (SensorCommand) -> Bool) {
        advance(now:now,refreshNow:{ now },send:send)
    }

    /// Native drivers must resample uptime after every synchronous send:
    /// a slow first send must not authorize a stale second onset.
    public mutating func advance(now: UInt64, refreshNow: () -> UInt64,
                                 shouldStop: () -> Bool = { false },
                                 send: (SensorCommand) -> Bool) {
        guard state == .playing else { return }
        var current=now
        while state == .playing {
            // Stop before admitting another note into the output ledger.
            // Cleanup bypasses this admission fence and still sends offs.
            if shouldStop() { retire(.stopped,send:send); return }
            guard current >= last else { retire(.faulted,send:send); return }
            last=current
            let elapsed=current-start
            guard next < events.count, events[next].offsetNS <= elapsed else {
                if elapsed >= durationNS {
                    retire(outstanding.isEmpty ? .finished : .faulted,send:send)
                }
                return
            }
            let event=events[next]
            guard elapsed-event.offsetNS <= Self.maximumLatenessNS else {
                retire(.faulted,send:send); return
            }
            let cmd=event.command
            if cmd.value > 0 {
                if events[(next+1)...].contains(where:{
                    $0.command.destination == cmd.destination && $0.command.value == 0 && $0.offsetNS <= elapsed
                }) {
                    retire(.faulted,send:send); return
                }
                outstanding.insert(cmd.destination)
            }
            guard send(cmd) else { retire(.faulted,send:send); return }
            if cmd.value == 0 { outstanding.remove(cmd.destination) }
            next += 1
            current=refreshNow()
        }
    }

    public mutating func stop(send: (SensorCommand) -> Bool) {
        if state == .ready || state == .playing { retire(.stopped,send:send) }
    }

    /// External sink/identity failure is terminal, even during silence.
    /// Keep outstanding debt; never silently return a successful stop.
    public mutating func abort(send: (SensorCommand) -> Bool) {
        if state == .ready || state == .playing { retire(.faulted,send:send) }
    }

    public mutating func retryCleanup(send: (SensorCommand) -> Bool) {
        guard state != .ready && state != .playing else { return }
        clean(send:send)
    }

    private mutating func retire(_ terminal: State, send: (SensorCommand) -> Bool) {
        state = terminal
        clean(send:send)
    }

    private mutating func clean(send: (SensorCommand) -> Bool) {
        for target in outstanding.sorted(by:{
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.number < $1.number
        }) {
            if send(.init(target,value:0)) { outstanding.remove(target) }
        }
    }
}
