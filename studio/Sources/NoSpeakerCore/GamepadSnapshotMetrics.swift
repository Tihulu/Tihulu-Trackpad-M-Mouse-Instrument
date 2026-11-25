/// Session-bearing native gamepad snapshots only. These counters measure
/// work admission, not hardware sampling rate or audio latency.
public struct GamepadSnapshotMetrics: Sendable {
    public private(set) var accepted = 0
    public private(set) var skippedDuplicates = 0
    public private(set) var mappedEvents = 0
    public init() {}

    mutating func record(skipped: Bool, events: Int) {
        guard events >= 0, !skipped || events == 0 else { return }
        if accepted < Int.max { accepted += 1 }
        if skipped, skippedDuplicates < Int.max { skippedDuplicates += 1 }
        mappedEvents += min(events,Int.max-mappedEvents)
    }
}
