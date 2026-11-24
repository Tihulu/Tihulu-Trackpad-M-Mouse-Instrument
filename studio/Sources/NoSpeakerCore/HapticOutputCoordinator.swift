import Foundation

public enum HapticOutputCoordinatorError: Error, Equatable {
    case retired
}

/// Serialized output owner for the candidate shared mixer. The injected sink
/// must be synchronous and must not reenter this coordinator. A future host
/// owns the tick cadence, driver lifetime, and any user-facing failure state.
/// No background timer or production hardware access is started here.
public final class HapticOutputCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private let sink: @Sendable (HapticFrame) throws -> Void
    private var mixer = HapticFrameMixer()
    private var retired = false

    public init(clock: @escaping @Sendable () -> Double = {
        ProcessInfo.processInfo.systemUptime
    }, sink: @escaping @Sendable (HapticFrame) throws -> Void) {
        self.clock = clock
        self.sink = sink
    }

    public func begin(_ source: HapticMixSource, priority: Int = 0,
                      mode: HapticMixMode = .continuous) throws -> HapticMixLease {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { throw HapticOutputCoordinatorError.retired }
        return mixer.begin(source, priority: priority, mode: mode)
    }

    @discardableResult
    public func submit(_ frame: HapticFrame?, from lease: HapticMixLease,
                       masterLevel: Double = 1) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return false }
        // Sample time only after taking the lock to avoid cross-source
        // timestamp reordering by concurrent callers.
        return mixer.submit(frame, from: lease, masterLevel: masterLevel, now: clock())
    }

    /// A release waits for any in-flight output to finish. Only this lease
    /// is removed; other active sources remain eligible for the next tick.
    @discardableResult
    public func release(_ lease: HapticMixLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return false }
        return mixer.release(lease)
    }

    /// Terminal for this owner. Already accepted hardware frames may finish
    /// their bounded duration; no subsequent sink call is permitted.
    public func retire() {
        lock.lock()
        defer { lock.unlock() }
        retired = true
        mixer.releaseAll()
    }

    public var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    public var sourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mixer.sourceCount
    }

    /// Called by one external scheduler; never queues or replays missed ticks.
    /// Sink failure retires the whole owner rather than retrying indefinitely.
    @discardableResult
    public func tick(sliceMS: Double = 8) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return false }
        guard let frame = mixer.render(now: clock(), sliceMS: sliceMS) else { return false }
        do {
            try sink(frame)
            return true
        } catch {
            retired = true
            mixer.releaseAll()
            throw error
        }
    }
}
