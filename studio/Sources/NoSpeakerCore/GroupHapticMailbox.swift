import Foundation

/// Single latest frame, no queued driver work. Synchronization is supplied
/// by the native adapter; the driver must never run under that lock.
public struct GroupHapticMailbox: Sendable {
    public struct Sample: Sendable, Equatable {
        public let frame:HapticFrame?
        public let masterLevel:Double
    }
    private var fence = GroupHapticFreshness()
    private var sample:Sample?
    public var retired:Bool { fence.retired || closed }
    private var closed = false

    public init(now:Double) {
        _ = fence.refresh(now:now)
    }

    @discardableResult
    public mutating func publish(frame:HapticFrame?,masterLevel:Double,now:Double) -> Bool {
        guard !closed,fence.refresh(now:now) else { sample = nil; return false }
        let level = masterLevel.isFinite ? min(1,max(0,masterLevel)) : 0
        sample = .init(frame:level > 0 ? frame : nil,masterLevel:level)
        return true
    }

    public mutating func read(now:Double) -> Sample? {
        guard !closed,fence.check(now:now) else { sample = nil; return nil }
        return sample
    }

    public mutating func close() {
        closed = true
        sample = nil
    }
}
