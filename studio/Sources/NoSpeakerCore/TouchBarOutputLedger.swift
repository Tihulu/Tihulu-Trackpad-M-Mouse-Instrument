/// Dedicated Touch Bar endpoint cleanup, independent of the legacy MIDI bridge.
public struct TouchBarOutputLedger: Sendable {
    private var output = PatchOutputLedger()
    private var selectors = MIDISelectorCleanup()
    public init() {}
    public var isEmpty: Bool { output.outstanding.isEmpty && selectors.isEmpty }

    public mutating func deliver(_ command: SensorCommand, send: (SensorCommand) -> Bool) -> Bool {
        output.deliver(command, send:send)
    }

    private static func cc(_ number: Int, _ value: Int, _ channel: Int) -> SensorCommand {
        .init(.init(.controlChange, channel:channel, number:number), value:value)
    }

    public mutating func configureBendRange(channel: Int, send: (SensorCommand) -> Bool) -> Bool {
        guard isEmpty, (0...15).contains(channel) else { return false }
        let commands = [(101,0),(100,0),(6,12),(38,0),(101,127),(100,127)]
            .map { Self.cc($0.0,$0.1,channel) }
        return selectors.configure(commands,send:send)
    }

    public mutating func releaseAll(send: (SensorCommand) -> Bool) -> Bool {
        _ = output.releaseAll(send:send)
        _ = selectors.releaseAll(send:send)
        return isEmpty
    }
}
