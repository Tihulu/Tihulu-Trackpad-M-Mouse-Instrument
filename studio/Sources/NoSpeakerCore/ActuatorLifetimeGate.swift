import Foundation

public enum ActuatorLifetimeError: LocalizedError, Equatable {
    case retired
    public var errorDescription: String? {
        "This actuator session has ended. Reconnect to create a new session."
    }
}

/// Serializes hardware submissions with terminal revocation. Every operation
/// touching a driver instance must enter the same gate. Retirement waits for
/// an in-flight operation, runs cleanup once, then rejects all later work,
/// including an implicit open requested by an obsolete producer.
public final class ActuatorLifetimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var retired = false

    public init() {}

    public func withActive<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { throw ActuatorLifetimeError.retired }
        return try body()
    }

    public func snapshot<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func retire(_ cleanup: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return }
        retired = true
        cleanup()
    }
}
