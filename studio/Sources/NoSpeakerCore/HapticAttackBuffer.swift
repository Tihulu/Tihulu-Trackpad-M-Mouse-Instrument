/// Short physical attacks may begin and end between two actuator ticks.
/// Preserve a small number of recent attack intents, never an unbounded
/// musical backlog. The caller owns synchronization and session fencing.
/// This is a best-effort physical render policy, NOT a MIDI event queue.
public struct HapticAttackBuffer<Payload: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Payload
        let time: Double
    }
    public static var capacity: Int { 4 }
    public static var maximumAge: Double { 0.040 }
    private var entries: [Entry] = []
    public init() {}
    public var isEmpty: Bool { entries.isEmpty }
    public mutating func offer(_ value: Payload, now: Double) {
        guard now.isFinite, now >= 0 else { return }
        prune(now:now)
        if entries.count >= Self.capacity { entries.removeFirst() }
        entries.append(.init(value:value,time:now))
    }
    private mutating func prune(now: Double) {
        entries.removeAll { now < $0.time || now-$0.time >= Self.maximumAge }
    }
    public mutating func take(now: Double) -> Payload? {
        guard now.isFinite, now >= 0 else { removeAll(); return nil }
        prune(now:now)
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst().value
    }
    public mutating func removeAll() { entries.removeAll(keepingCapacity:true) }
}
