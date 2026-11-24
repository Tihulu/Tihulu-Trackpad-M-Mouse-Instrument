/// Retry incomplete RPN selector transactions on their original endpoint.
/// Input is an internally generated ordered RPN configuration sequence.
/// Configuration data already delivered is not rolled back.
public struct MIDISelectorCleanup: Sendable {
    private var pending: Set<Int> = []
    public init() {}
    public var isEmpty: Bool { pending.isEmpty }

    public mutating func configure(_ commands: [SensorCommand], send: (SensorCommand) -> Bool) -> Bool {
        guard isEmpty else { return false }
        for command in commands {
            let target = command.destination
            guard target.isValid else { return false }
            let isCC = target.kind == .controlChange
            // Record before attempting the first selector write; a failed
            // transmission may have been delivered to the receiver.
            if isCC && target.number == 101 && command.value == 0 {
                pending.insert(target.channel)
            }
            guard send(command) else { return false }
            // Internal sequences always null MSB then LSB. A successful
            // final null LSB closes this selector transaction.
            if isCC && target.number == 100 && command.value == 127 {
                pending.remove(target.channel)
            }
        }
        return isEmpty
    }

    public mutating func releaseAll(send: (SensorCommand) -> Bool) -> Bool {
        for channel in pending.sorted() {
            let msb = send(.init(.init(.controlChange,channel:channel,number:101),value:127))
            let lsb = send(.init(.init(.controlChange,channel:channel,number:100),value:127))
            if msb && lsb { pending.remove(channel) }
        }
        return isEmpty
    }
}
