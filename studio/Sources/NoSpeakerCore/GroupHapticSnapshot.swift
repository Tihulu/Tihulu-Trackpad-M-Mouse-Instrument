/// A transient retains its original monotonic receipt time across the
/// producer/consumer boundary. Transport must never renew its age.
public struct GroupHapticAttack: Sendable, Equatable {
    public let frame:HapticFrame
    public let time:Double
    public init(frame:HapticFrame,time:Double) { self.frame = frame; self.time = time }
    public func isFresh(now:Double) -> Bool {
        now.isFinite && time.isFinite && time >= 0 && now >= time &&
        now-time < HapticAttackBuffer<HapticFrame>.maximumAge
    }
}

public struct GroupHapticSnapshot: Sendable {
    public let held:HapticFrame?
    public let attacks:[GroupHapticAttack]
    public let epoch:UInt64
    public init(held:HapticFrame?,attacks:[GroupHapticAttack],epoch:UInt64) {
        self.held = held; self.attacks = attacks; self.epoch = epoch
    }
}
