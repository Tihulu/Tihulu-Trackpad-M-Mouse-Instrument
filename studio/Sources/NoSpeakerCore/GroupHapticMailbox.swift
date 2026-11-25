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
    private var attackEpoch:UInt64?
    private var attacks:[GroupHapticAttack] = []
    public var retired:Bool { fence.retired || closed }
    private var closed = false

    public init(now:Double) {
        _ = fence.refresh(now:now)
    }

    @discardableResult
    public mutating func publish(frame:HapticFrame?,masterLevel:Double,now:Double) -> Bool {
        publish(snapshot:.init(held:frame,attacks:[],epoch:attackEpoch ?? 0),masterLevel:masterLevel,now:now)
    }

    @discardableResult
    public mutating func publish(snapshot:GroupHapticSnapshot,masterLevel:Double,now:Double) -> Bool {
        guard !closed,fence.refresh(now:now) else { sample = nil; attacks.removeAll(); return false }
        if attackEpoch != snapshot.epoch { attacks.removeAll(); attackEpoch = snapshot.epoch }
        let level = masterLevel.isFinite ? min(1,max(0,masterLevel)) : 0
        sample = .init(frame:level > 0 ? snapshot.held : nil,masterLevel:level)
        attacks.removeAll { !$0.isFresh(now:now) }
        if level == 0 { attacks.removeAll() }
        else {
            for item in snapshot.attacks.suffix(HapticAttackBuffer<HapticFrame>.capacity) where item.isFresh(now:now) {
                if attacks.count >= HapticAttackBuffer<HapticFrame>.capacity { attacks.removeFirst() }
                attacks.append(item)
            }
        }
        return true
    }

    public mutating func read(now:Double) -> Sample? {
        guard !closed,fence.check(now:now) else { sample = nil; attacks.removeAll(); return nil }
        guard let sample else { return nil }
        attacks.removeAll { !$0.isFresh(now:now) }
        let attack = attacks.isEmpty ? nil : attacks.removeFirst().frame
        return .init(frame:LiveHapticFrameSelection.select(held:sample.frame,attack:attack),masterLevel:sample.masterLevel)
    }

    public mutating func close() {
        closed = true
        sample = nil
        attacks.removeAll()
    }
}
