import Foundation

/// Validated clip -> monotonic transport events. Off events precede on
/// events at equal ticks, and on events carry their expiry deadline.
public struct MIDIClipSchedule: Sendable {
    public struct Event: Equatable, Sendable {
        public let tick: Int
        public let endTick: Int
        public let command: SensorCommand
        public var isNoteOn: Bool { command.value > 0 }
    }
    public let events: [Event]
    public let length: Int
    public let bpm: Double
    public init(_ input: MIDIClip) throws {
        let clip = try input.validated()
        length = clip.length
        bpm = clip.bpm
        events = clip.notes.flatMap { n -> [Event] in
            let key = SensorDestination(.note, channel: n.channel, number: n.pitch)
            return [
                .init(tick: n.start, endTick: n.start + n.duration, command: .init(key, value: n.velocity)),
                .init(tick: n.start + n.duration, endTick: n.start + n.duration, command: .init(key, value: 0))
            ]
        }.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.isNoteOn != $1.isNoteOn { return !$0.isNoteOn }
            if $0.command.destination.channel != $1.command.destination.channel {
                return $0.command.destination.channel < $1.command.destination.channel
            }
            return $0.command.destination.number < $1.command.destination.number
        }
    }
    public func seconds(at tick: Int) -> Double {
        Double(tick) * 60 / bpm / Double(MIDIClip.ppq)
    }
}

/// Attempted note-ons are recorded before transmission, then removed
/// only when their explicit release succeeds. Failed sends cannot silently
/// clear the ledger. Owned by a single transport actor.
public struct MIDIClipNoteLedger: Sendable {
    public private(set) var outstanding: Set<SensorDestination> = []
    public init() {}
    public mutating func deliver(_ command: SensorCommand,
                                 send: (SensorCommand) -> Bool) -> Bool {
        let key = command.destination
        guard key.kind == .note, key.isValid, (0...127).contains(command.value) else { return false }
        if command.value > 0 {
            guard !outstanding.contains(key) else { return false }
            outstanding.insert(key)
        } else if !outstanding.contains(key) { return true }
        guard send(command) else { return false }
        if command.value == 0 { outstanding.remove(key) }
        return true
    }
    public mutating func releaseAll(send: (SensorCommand) -> Bool) -> Bool {
        for key in outstanding.sorted(by: {
            $0.channel == $1.channel ? $0.number < $1.number : $0.channel < $1.channel
        }) {
            if send(.init(key, value: 0)) { outstanding.remove(key) }
        }
        return outstanding.isEmpty
    }
}
