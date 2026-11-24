/// Conservative gate debt: a failed onset may have reached the receiver.
/// Never remove an outstanding gate on a failed release.
public struct LegacyGateReleaseDebt: Sendable {
    public struct Message: Equatable, Sendable {
        public let status,data1,data2: Int
        public init(_ status: Int,_ data1: Int,_ data2: Int) {
            self.status = status; self.data1 = data1; self.data2 = data2
        }
    }
    private var notes: Set<SensorDestination> = []
    private var pedals: Set<Int> = []
    public init() {}
    public var isEmpty: Bool { notes.isEmpty && pedals.isEmpty }
    public var pending: [Message] {
        pedals.sorted().map { .init(0xb0 | $0,64,0) } +
        notes.sorted { $0.channel == $1.channel ? $0.number < $1.number : $0.channel < $1.channel }
            .map { .init(0x80 | $0.channel,$0.number,0) }
    }
    public static func isGate(_ message: Message) -> Bool {
        let type = message.status & 0xf0
        return type == 0x80 || type == 0x90 || (type == 0xb0 && message.data1 == 64)
    }
    public mutating func record(_ message: Message, succeeded: Bool) {
        let type = message.status & 0xf0, channel = message.status & 15
        if type == 0x80 || type == 0x90 {
            let note = SensorDestination(.note,channel:channel,number:message.data1)
            if type == 0x90 && message.data2 > 0 { notes.insert(note) }
            else if succeeded { notes.remove(note) }
        } else if type == 0xb0 && message.data1 == 64 {
            if message.data2 >= 64 { pedals.insert(channel) }
            else if succeeded { pedals.remove(channel) }
        }
    }
}
