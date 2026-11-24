/// Main-actor callers capture a gesture revision at press/edit start.
/// A release, Stop, or mapping replacement can retire all older gestures.
/// Discrete slider inputs (e.g. keyboard/accessibility) have no held gesture.
public struct TouchBarGestureEpoch: Sendable {
    public private(set) var revision: UInt64 = 0
    public init() {}
    public mutating func invalidate() { revision &+= 1 }
    /// Retiring an old optional endpoint's debt must not cancel current
    /// legacy MIDI gestures or their pending note-off timers.
    @discardableResult
    public mutating func invalidateOptionalOutput(sendsHaptics: Bool, armed: Bool) -> Bool {
        guard sendsHaptics || armed else { return false }
        invalidate()
        return true
    }
    public func accepts(_ captured: UInt64) -> Bool { captured == revision }
    public func permitsSample(captured: UInt64?) -> Bool {
        captured.map { accepts($0) } ?? true
    }
}
