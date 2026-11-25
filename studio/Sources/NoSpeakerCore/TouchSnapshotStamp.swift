/// A computed touch snapshot is usable only in the revision that produced it.
/// Reject reordered snapshots without coalescing normally ordered touch edges.
public struct TouchSnapshotStamp: Equatable, Sendable {
    public let revision, sequence: UInt64
    public init(revision: UInt64, sequence: UInt64) {
        self.revision = revision; self.sequence = sequence
    }
}
public struct TouchSnapshotCursor: Sendable {
    private var last: TouchSnapshotStamp?
    public init() {}
    public mutating func accept(_ stamp: TouchSnapshotStamp, currentRevision: UInt64) -> Bool {
        guard stamp.revision == currentRevision else { return false }
        if let last, last.revision == stamp.revision, stamp.sequence <= last.sequence { return false }
        last = stamp
        return true
    }
    public mutating func reset() { last = nil }
}
public struct TouchConsumerPublicationFence: Sendable {
    private var excludedThrough: UInt64 = 0
    public init() {}
    public mutating func begin(after sequence:UInt64) { excludedThrough = sequence }
    public func permits(_ stamp:TouchSnapshotStamp,selectedSource:Bool) -> Bool {
        selectedSource && stamp.sequence > excludedThrough
    }
    public mutating func reset() { excludedThrough = 0 }
}
