/// Reservations for released MPE member channels whose notes can still sound
/// under CC64. Allocation never steals an active note or a sustained channel.
public struct LegacyMPEChannelPool: Sendable {
    private var retired: [Int:Bool] = [:]
    public init() {}
    public var reserved: Set<Int> { Set(retired.keys) }

    public func next(occupied: Set<Int>, sustained: Set<Int>) -> Int? {
        (1...15).first { $0 != 9 && !occupied.contains($0) &&
            !sustained.contains($0) && retired[$0] == nil }
    }

    /// True means a bend neutral may be emitted immediately.
    public mutating func retire(channel: Int, sustained: Bool, fretless: Bool) -> Bool {
        guard (1...15).contains(channel), channel != 9 else { return false }
        if sustained {
            retired[channel] = (retired[channel] ?? false) || fretless
            return false
        }
        return fretless
    }

    /// Call after outgoing pedal transitions, not before them.
    public mutating func pedalChanged(sustained: Set<Int>) -> [Int] {
        let released = reserved.subtracting(sustained).sorted()
        let bends = released.filter { retired[$0] == true }
        for channel in released { retired.removeValue(forKey:channel) }
        return bends
    }
}
