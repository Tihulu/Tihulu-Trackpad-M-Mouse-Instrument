import Foundation

/// Serialized owner slot for one native Relative host and its transport.
/// Retain the same host until terminal cleanup succeeds. A stale watchdog
/// or Stop callback must never dispose the replacement host's transaction.
@MainActor
public final class NativeHelperRelativeHostLifetime<Host: AnyObject> {
    public struct Token: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    public enum Phase: Equatable, Sendable { case idle, active, closing }

    private enum State {
        case idle
        case active(Token, Host)
        case retiring(Token, Host)
        case pending(Token, Host)
        case finishing(Token, Host)
    }
    private var state = State.idle

    public init() {}

    public var phase: Phase {
        switch state {
        case .idle: return .idle
        case .active: return .active
        default: return .closing
        }
    }

    /// The caller constructs an inert host; installation does not arm MIDI.
    public func install(_ host: Host) -> Token? {
        guard case .idle = state else { return nil }
        let token = Token()
        state = .active(token, host)
        return token
    }

    public func activeHost(for token: Token) -> Host? {
        guard case .active(let current, let host) = state, current == token else { return nil }
        return host
    }

    /// Invalidate live admission BEFORE permanent close. The same captured
    /// host must own both callbacks, including its original MIDI service.
    /// Neither callback may install another host or retry during transition.
    @discardableResult
    public func close(_ token: Token, retire: (Host) -> Void, finish: (Host) -> Bool) -> Bool {
        guard case .active(let current, let host) = state, current == token else { return false }
        state = .retiring(current, host)
        retire(host)
        state = .pending(current, host)
        return retry(token, finish: finish)
    }

    /// Retry only logical disposal after actual scoped debt recovery. Never
    /// use this as an onset, a fabricated neutral or a second close/send.
    @discardableResult
    public func retry(_ token: Token, finish: (Host) -> Bool) -> Bool {
        guard case .pending(let current, let host) = state, current == token else { return false }
        state = .finishing(current, host)
        let clean = finish(host)
        state = clean ? .idle : .pending(current, host)
        return clean
    }
}
