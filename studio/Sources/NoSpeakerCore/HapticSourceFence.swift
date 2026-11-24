import Foundation

/// A source-local submission fence. Starting a new lease invalidates the old
/// lease, and revocation drains any submission already executing. The driver
/// still owns the separate, terminal actuator lifetime fence.
public final class HapticSourceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    public init() {}

    public func begin() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        current = token
        return token
    }

    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }

    /// Wait for an in-flight submission without invalidating the lease.
    /// The caller first changes its enabled state; later submissions must
    /// recheck that state inside submit, not rely on a stale render snapshot.
    public func drain() {
        lock.lock()
        lock.unlock()
    }

    @discardableResult
    public func submit(_ token: UUID, _ body: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == token else { return false }
        try body()
        return true
    }
}
