/// Track actual attempted continuous writes, not just intended owners.
/// Retain a cleanup message until CoreMIDI accepts the neutral submission.
public struct LegacyControllerReleaseDebt: Sendable {
    public typealias Message = LegacyGateReleaseDebt.Message
    private struct Key: Hashable, Sendable {
        let status, number: Int
    }
    private var targets: [Key:Message] = [:]
    private var incompleteRangeChannels: Set<Int> = []
    public init() {}
    public var isEmpty: Bool { targets.isEmpty && incompleteRangeChannels.isEmpty }
    public var pendingRanges: [Int] { incompleteRangeChannels.sorted() }
    public var pending: [Message] {
        targets.values.sorted {
            if $0.status != $1.status { return $0.status < $1.status }
            return $0.data1 < $1.data1
        }
    }

    public mutating func beginRange(channel: Int) { if (0...15).contains(channel) { incompleteRangeChannels.insert(channel) } }
    public mutating func completeRange(channel: Int) { incompleteRangeChannels.remove(channel) }

    public static func neutral(for message: Message) -> Int? {
        switch message.status & 0xf0 {
        case 0xb0:
            guard HelperCCPolicy.permits(message.data1) else { return nil }
            return [7,11].contains(message.data1) ? 127 : 0
        case 0xd0: return 0
        case 0xe0: return 8192
        default: return nil
        }
    }
    public mutating func record(_ message: Message, neutral: Int, succeeded: Bool) {
        let key: Key
        let value: Int
        let release: Message
        switch message.status & 0xf0 {
        case 0xb0:
            guard HelperCCPolicy.permits(message.data1),(0...127).contains(neutral) else { return }
            key = .init(status:message.status,number:message.data1)
            value = message.data2
            release = .init(message.status,message.data1,neutral)
        case 0xd0:
            guard neutral == 0 else { return }
            key = .init(status:message.status,number:0)
            value = message.data1
            release = .init(message.status,0,0)
        case 0xe0:
            guard neutral == 8192 else { return }
            key = .init(status:message.status,number:0)
            value = message.data1 | (message.data2 << 7)
            release = .init(message.status,0,64)
        default: return
        }
        if succeeded && value == neutral { targets.removeValue(forKey:key) }
        else { targets[key] = release }
    }
}

/// Keep cleanup submissions possible after input and normal output stop.
/// Replacement must not discard unresolved receiver-state obligations.
public enum LegacyRecoveryPolicy {
    /// Release callbacks arriving after Stop are not new performance intent.
    public static func permitsSustainEvent(running: Bool, pressed: Bool) -> Bool {
        running || pressed
    }
    public static func permitsSend(enabled: Bool, faulted: Bool, cleaning: Bool) -> Bool {
        cleaning || (enabled && !faulted)
    }
    public static func permitsReplacement(gatesPending: Bool, controllersPending: Bool, unknownFailure: Bool) -> Bool {
        !gatesPending && !controllersPending && !unknownFailure
    }
}
