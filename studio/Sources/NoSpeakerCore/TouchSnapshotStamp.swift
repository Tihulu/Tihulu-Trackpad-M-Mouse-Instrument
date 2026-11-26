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
public struct PhysicalSurfaceObservation: Sendable, Equatable {
    public let stamp:TouchSnapshotStamp
    public let receivedAt:Double
    public init(stamp:TouchSnapshotStamp,receivedAt:Double) {
        self.stamp = stamp; self.receivedAt = receivedAt
    }
}

public struct PhysicalSurfaceSnapshotCache<Surface:Hashable & Sendable,Contact:Sendable>: Sendable {
    private var states: [Surface:[Contact]] = [:]
    private var observations:[Surface:PhysicalSurfaceObservation] = [:]
    public init() {}
    public mutating func replace(_ surface:Surface,contacts:[Contact],observation:PhysicalSurfaceObservation? = nil) {
        if contacts.isEmpty {
            states.removeValue(forKey:surface)
            observations.removeValue(forKey:surface)
        } else {
            states[surface] = contacts
            observations[surface] = observation
        }
    }
    public var touchingSurfaces:Set<Surface> { Set(states.keys) }
    /// An unrelated surface publication cannot refresh a held contact's
    /// click-attribution timestamp or mapping revision.
    public var singleTouchObservation:PhysicalSurfaceObservation? {
        guard states.count == 1,let surface = states.keys.first else { return nil }
        return observations[surface]
    }
    public func combined(order:[Surface]) -> [Contact] { order.flatMap { states[$0] ?? [] } }
    public mutating func reset() { states.removeAll(); observations.removeAll() }
}

/// Strict deadline admission for monotonic receipts. Comparing the
/// representable deadline as well as elapsed time prevents subtraction
/// rounding from extending the original window at nonzero uptime.
public enum MonotonicReceiptAdmission {
    public static func permits(receipt:Double,now:Double,maximumAge:Double)->Bool {
        receipt.isFinite && now.isFinite && maximumAge.isFinite && maximumAge>0 &&
            receipt>=0 && now>=receipt && now-receipt<maximumAge &&
            now<receipt+maximumAge
    }
}

/// A single receipt has one monotonic admission fence, shared across synchronous
/// consumers. A rejection is irreversible even if the clock later recovers.
public struct PhysicalReceiptSendFence: Sendable {
    private let receipt,maximumAge:Double
    private var lastNow:Double?
    public private(set) var rejected=false
    public init(receipt:Double,maximumAge:Double,initialNow:Double? = nil) {
        self.receipt=receipt; self.maximumAge=maximumAge; self.lastNow=initialNow
    }
    public mutating func permits(now:Double)->Bool {
        guard !rejected, lastNow.map({ now >= $0 }) ?? true,
              MonotonicReceiptAdmission.permits(receipt:receipt,now:now,maximumAge:maximumAge) else {
            rejected=true
            return false
        }
        lastNow=now
        return true
    }
}

/// The shared Touch/Helper inbox cannot authorize onsets from a
/// future, nonfinite or expired monotonic publication timestamp.
public enum TouchPublicationAdmission {
    public static let maximumAge:Double=0.150
    public static func permits(queuedAt:Double,now:Double)->Bool {
        MonotonicReceiptAdmission.permits(receipt:queuedAt,now:now,maximumAge:maximumAge)
    }

    /// Pedal reconciliation and Touch output may synchronously block. A
    /// later consumer must not inherit the earlier admission decision.
    /// On false the caller retires the physical session and its ownership.
    public static func dispatch(queuedAt:Double,now:()->Double,
                                prepare:()->Void,touch:()->Void,helper:()->Void)->Bool {
        var fence=PhysicalReceiptSendFence(receipt:queuedAt,maximumAge:maximumAge)
        return dispatch(permits:{ fence.permits(now:now()) },prepare:prepare,touch:touch,helper:helper)
    }

    /// The controller may share this exact same fence with individual sends.
    public static func dispatch(permits:()->Bool,prepare:()->Void,touch:()->Void,helper:()->Void)->Bool {
        guard permits() else { return false }
        prepare()
        guard permits() else { return false }
        touch()
        guard permits() else { return false }
        helper()
        return permits()
    }
}

/// Batch-level output admission for the single-owner Builder. Rejection
/// happens before handing a command to the transport/debt ledger. The
/// caller retires its entire Builder session using the actual output
/// ledger, not the router's speculative command list.
public enum PhysicalReceiptCommandBatch {
    public enum Outcome: Equatable, Sendable {
        case completed, expired, transportFailed
    }
    public static func dispatch<Command>(_ commands:[Command],
                                         fence:inout PhysicalReceiptSendFence?,
                                         now:()->Double,
                                         send:(Command)->Bool)->Outcome {
        for command in commands {
            if fence != nil, fence?.permits(now:now()) != true { return .expired }
            guard send(command) else { return .transportFailed }
        }
        if fence != nil, fence?.permits(now:now()) != true { return .expired }
        return .completed
    }
}
