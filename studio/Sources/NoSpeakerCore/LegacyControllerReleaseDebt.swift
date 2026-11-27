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

    /// Intentional persistent gain has no known external baseline. Never
    /// fabricate a maximum-volume cleanup for it. Failed sends need manual recovery.
    public mutating func forgetPersistentGain(_ message:Message) {
        guard message.status & 0xf0 == 0xb0,[7,11].contains(message.data1) else { return }
        targets.removeValue(forKey:.init(status:message.status,number:message.data1))
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
    /// Full-source Stop only. Read each ledger at its original cleanup phase;
    /// the caller's wire callback records actual results in those ledgers.
    /// Always attempt both RPN null selectors, even if the first fails.
    public static func drainAttemptedCleanup(
        pendingGates: () -> [LegacyGateReleaseDebt.Message],
        pendingRanges: () -> [Int],
        pendingControllers: () -> [LegacyGateReleaseDebt.Message],
        send: (LegacyGateReleaseDebt.Message, Int?, Bool) -> Bool,
        completeRange: (Int) -> Void
    ) {
        for message in pendingGates() { _ = send(message, nil, false) }
        for channel in pendingRanges() {
            let msb = send(.init(0xb0 | channel, 101, 127), nil, true)
            let lsb = send(.init(0xb0 | channel, 100, 127), nil, true)
            if msb && lsb { completeRange(channel) }
        }
        for message in pendingControllers() {
            let neutral = (message.status & 0xf0 == 0xb0) ? message.data2 : LegacyControllerReleaseDebt.neutral(for: message)
            _ = send(message, neutral, false)
        }
    }

    /// Release callbacks arriving after Stop are not new performance intent.
    public static func permitsSustainEvent(running: Bool, pressed: Bool) -> Bool {
        running || pressed
    }
    /// A neutralization callback is cleanup, not permission to start output.
    public static func permitsControlEvent(running: Bool, releaseOnly: Bool) -> Bool {
        running || !releaseOnly
    }
    /// Reusing an already-running endpoint must not report success while
    /// its outgoing transport is faulted or requires explicit DAW recovery.
    /// Ordinary live note/controller obligations are not a reason to refuse.
    public static func permitsActiveStart(faulted: Bool, unknownFailure: Bool, cleaning: Bool) -> Bool {
        !faulted && !unknownFailure && !cleaning
    }
    public static func permitsSend(enabled: Bool, faulted: Bool, cleaning: Bool) -> Bool {
        cleaning || (enabled && !faulted)
    }
    public static func permitsReplacement(gatesPending: Bool, controllersPending: Bool, unknownFailure: Bool) -> Bool {
        !gatesPending && !controllersPending && !unknownFailure
    }
}
