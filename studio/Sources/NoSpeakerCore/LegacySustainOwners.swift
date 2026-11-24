/// Outgoing CC64 owners on one shared MIDI endpoint. Releases are scoped:
/// another owner holding the same channel keeps that pedal active.
public struct LegacySustainOwners: Sendable {
    public enum Owner: Hashable, Sendable { case touch, helper, touchBar }
    private var owners: [Owner:Set<Int>] = [:]
    public init() {}
    public func channels(for owner: Owner) -> Set<Int> { owners[owner] ?? [] }
    public var active: Set<Int> { owners.values.reduce(into:Set<Int>()) { $0.formUnion($1) } }

    public mutating func replace(_ owner: Owner, channels: Set<Int>) -> [SensorCommand] {
        let before = active
        let valid = channels.filter { (0...15).contains($0) }
        if valid.isEmpty { owners.removeValue(forKey:owner) }
        else { owners[owner] = valid }
        let after = active
        return before.subtracting(after).sorted().map { .init(.init(.sustain,channel:$0),value:0) }
            + after.subtracting(before).sorted().map { .init(.init(.sustain,channel:$0),value:127) }
    }
    public mutating func releaseAll() -> [SensorCommand] {
        let before = active
        owners.removeAll()
        return before.sorted().map { .init(.init(.sustain,channel:$0),value:0) }
    }
}
