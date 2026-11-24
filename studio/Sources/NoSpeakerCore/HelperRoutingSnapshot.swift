/// Tracks whether the previous helper configuration actually owned outgoing
/// controls. Comparing the complete routing avoids leaving an old CC target
/// latched after a live mapping change. Does not send MIDI itself.
public struct HelperRoutingSnapshot: Equatable, Sendable {
    public let sendToDAW: Bool
    public let channel, bendRange, vibratoCC, expressionCC: Int
    public init(sendToDAW: Bool, channel: Int, bendRange: Int, vibratoCC: Int, expressionCC: Int) {
        self.sendToDAW = sendToDAW
        self.channel = max(0,min(15,channel))
        self.bendRange = max(1,min(24,bendRange))
        self.vibratoCC = max(0,min(127,vibratoCC))
        self.expressionCC = max(0,min(127,expressionCC))
    }

    public func requiresRelease(before next: Self, otherMappingChanged: Bool) -> Bool {
        sendToDAW && (self != next || otherMappingChanged)
    }
}
