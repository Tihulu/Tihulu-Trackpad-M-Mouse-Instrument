/// Tracks whether the previous helper configuration actually owned outgoing
/// controls. Comparing the complete routing avoids leaving an old CC target
/// latched after a live mapping change. Does not send MIDI itself.
public struct HelperRoutingSnapshot: Equatable, Sendable {
    public let sendToDAW: Bool
    public let channel, bendRange, vibratoCC, expressionCC: Int
    public let configureReceiverBendRange:Bool
    public init(sendToDAW: Bool, channel: Int, bendRange: Int, vibratoCC: Int, expressionCC: Int,configureReceiverBendRange:Bool = false) {
        self.sendToDAW = sendToDAW
        self.configureReceiverBendRange = configureReceiverBendRange
        self.channel = max(0,min(15,channel))
        self.bendRange = max(1,min(24,bendRange))
        self.vibratoCC = max(0,min(127,vibratoCC))
        self.expressionCC = max(0,min(127,expressionCC))
    }

    public func requiresRelease(before next: Self, otherMappingChanged: Bool) -> Bool {
        sendToDAW && (self != next || otherMappingChanged)
    }
}


/// Arbitrary expressive sliders must not bypass dedicated sustain, RPN/NRPN,
/// bank selection or channel-mode state. Disabled controls do not reserve CCs.
public enum HelperCCPolicy {
    public static func permits(_ cc: Int) -> Bool {
        (0...119).contains(cc) && ![0,6,32,38,64,96,97,98,99,100,101].contains(cc)
    }
    public static var choices: [Int] { (0...119).filter(permits) }
    public static func permits(vibrato: Bool, expression: Bool, vibratoCC: Int, expressionCC: Int) -> Bool {
        (!vibrato || permits(vibratoCC)) && (!expression || permits(expressionCC)) &&
            !(vibrato && expression && vibratoCC == expressionCC)
    }
}
