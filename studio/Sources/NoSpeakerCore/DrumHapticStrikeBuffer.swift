/// One attack per down contact, including simultaneous fingers on distinct
/// pads. A lift rearms only that contact. Motor strikes are time-bounded,
/// separate from MIDI note ownership and release handling.
public struct DrumHapticStrikeBuffer: Sendable {
    private struct Strike: Sendable {
        let frame: HapticFrame
        let time: Double
    }
    private var down: Set<String> = []
    private var pending: [Strike] = []
    public static let capacity = 16
    public static let maximumAge = 0.040
    public init() {}
    public var hasPending: Bool { !pending.isEmpty }

    public mutating func receive(contacts: [String], now: Double,
                                 makeFrame: (String) -> HapticFrame?) {
        guard now.isFinite, now >= 0 else { return }
        prune(now:now)
        var next: Set<String> = []
        for id in contacts where next.insert(id).inserted {
            guard !down.contains(id), let frame = makeFrame(id) else { continue }
            if pending.count == Self.capacity { pending.removeFirst() }
            pending.append(.init(frame:frame,time:now))
        }
        down = next
    }

    private mutating func prune(now: Double) {
        pending.removeAll { now < $0.time || now-$0.time >= Self.maximumAge }
    }

    public mutating func drain(now: Double) -> [HapticFrame] {
        guard now.isFinite, now >= 0 else { pending.removeAll(); return [] }
        prune(now:now)
        let result = pending.map(\.frame)
        pending.removeAll(keepingCapacity:true)
        return result
    }

    public mutating func reset() {
        down.removeAll(keepingCapacity:true)
        pending.removeAll(keepingCapacity:true)
    }
}
