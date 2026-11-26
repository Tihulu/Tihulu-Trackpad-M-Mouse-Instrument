/// Channel pressure uses a two-byte MIDI 1.0 channel message.
public enum LegacyMIDI1Bytes {
    public static func channelMessage(status: Int, data1: Int, data2: Int) -> [UInt8] {
        let type = status & 0xf0
        let head = [UInt8(status & 0xff),UInt8(data1 & 0x7f)]
        return type == 0xc0 || type == 0xd0 ? head : head + [UInt8(data2 & 0x7f)]
    }
}

/// Touch-only channel pressure snapshot, independent of CC11.
public struct LegacyChannelPressure: Sendable {
    public struct Update: Equatable, Sendable {
        public let channel: Int
        public let value: Int
        public init(_ channel: Int,_ value: Int) { self.channel = channel; self.value = value }
    }
    public private(set) var values: [Int:Int] = [:]
    public init() {}
    public mutating func replace(_ next: [Int:Int]) -> [Update] {
        guard next.allSatisfy({ (0...15).contains($0.key) && (0...127).contains($0.value) }) else { return [] }
        guard values != next else { return [] }
        let previous = values
        values = next
        return Set(previous.keys).union(next.keys).sorted().compactMap { channel in
            if let value = next[channel] {
                return previous[channel] == value ? nil : .init(channel,value)
            }
            return previous[channel] == 0 ? nil : .init(channel,0)
        }
    }
    /// A physical pressure snapshot commits only individually admitted
    /// channel updates. Transport failures are recorded by the wire ledger.
    public mutating func replaceAdmitted(_ next:[Int:Int],permits:()->Bool,
                                         send:(Update)->Bool)->Bool {
        guard next.allSatisfy({ (0...15).contains($0.key) && (0...127).contains($0.value) }) else { return false }
        let channels=Set(values.keys).union(next.keys).filter { values[$0] != next[$0] }.sorted()
        for channel in channels {
            guard permits() else { return false }
            var staged=values
            staged[channel]=next[channel]
            var candidate=self
            for update in candidate.replace(staged) {
                guard permits(),send(update) else { return false }
            }
            self=candidate
        }
        return permits()
    }

    public mutating func release(_ channel: Int) -> [Update] {
        replace(values.filter { $0.key != channel })
    }
}
