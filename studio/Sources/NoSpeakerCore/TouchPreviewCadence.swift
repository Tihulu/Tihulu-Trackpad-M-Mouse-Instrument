/// Visual snapshots only. Do not use this gate for MIDI, note edges,
/// sustain recognition, haptic rendering or input ownership.
public struct TouchPreviewCadence: Sendable {
    private var last: Double?
    public init() {}
    public mutating func reset() { last = nil }
    public mutating func permits(now: Double, cleared: Bool) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        if cleared || last == nil || now < last! || now - last! >= 1.0/60.0 {
            last = now
            return true
        }
        return false
    }
}
