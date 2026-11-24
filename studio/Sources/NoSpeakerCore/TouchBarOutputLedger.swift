/// Dedicated Touch Bar endpoint cleanup, independent of the legacy MIDI bridge.
public struct TouchBarOutputLedger: Sendable {
    private var output = PatchOutputLedger()
    private var pendingRanges: Set<Int> = []
    public init() {}
    public var isEmpty: Bool { output.outstanding.isEmpty && pendingRanges.isEmpty }

    public mutating func deliver(_ command: SensorCommand, send: (SensorCommand) -> Bool) -> Bool {
        output.deliver(command, send:send)
    }

    private static func cc(_ number: Int, _ value: Int, _ channel: Int) -> SensorCommand {
        .init(.init(.controlChange, channel:channel, number:number), value:value)
    }

    public mutating func configureBendRange(channel: Int, send: (SensorCommand) -> Bool) -> Bool {
        guard isEmpty, (0...15).contains(channel) else { return false }
        pendingRanges.insert(channel)
        for (number,value) in [(101,0),(100,0),(6,12),(38,0),(101,127),(100,127)] {
            guard send(Self.cc(number,value,channel)) else { return false }
        }
        pendingRanges.remove(channel)
        return true
    }

    public mutating func releaseAll(send: (SensorCommand) -> Bool) -> Bool {
        _ = output.releaseAll(send:send)
        for channel in pendingRanges.sorted() {
            // Attempt both null selectors even if one fails. Never forget the
            // original channel after a profile change or failed delivery.
            let msb = send(Self.cc(101,127,channel))
            let lsb = send(Self.cc(100,127,channel))
            if msb && lsb { pendingRanges.remove(channel) }
        }
        return isEmpty
    }
}
