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

    
/// Physical publications remain ordered across note-mapping revisions.
/// The controller must still check its monitoring generation/token.
public struct TouchPublicationCursor: Sendable {
    private var last: UInt64?
    public init() {}
    public mutating func accept(_ stamp:TouchSnapshotStamp) -> Bool {
        guard last.map({ stamp.sequence > $0 }) ?? true else { return false }
        last = stamp.sequence
        return true
    }
    public mutating func reset() { last = nil }
}

/// Each native surface owns its own latest complete physical snapshot.
/// An empty snapshot clears only that surface; a note-map reset must not
/// reset this cache. Only the physical monitoring lifecycle owns reset.
public struct PhysicalSurfaceSnapshotCache<Surface:Hashable & Sendable,Contact:Sendable>: Sendable {
    private var states: [Surface:[Contact]] = [:]
    public init() {}
    public mutating func replace(_ surface:Surface,contacts:[Contact]) {
        if contacts.isEmpty { states.removeValue(forKey:surface) }
        else { states[surface] = contacts }
    }
    public var touchingSurfaces:Set<Surface> { Set(states.keys) }
    public func combined(order:[Surface]) -> [Contact] { order.flatMap { states[$0] ?? [] } }
    public mutating func reset() { states.removeAll() }
}
