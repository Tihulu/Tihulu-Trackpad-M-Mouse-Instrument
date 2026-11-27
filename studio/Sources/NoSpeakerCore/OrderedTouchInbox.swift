import Foundation

/// A single scheduled consumer drains committed snapshots in FIFO order.
/// No coalescing: even a very short down/up pair remains two snapshots.
/// Overflow invalidates the batch and requires scoped musical cleanup.
public final class OrderedTouchInbox<Payload: Sendable>: @unchecked Sendable {
    public struct Batch: Sendable {
        public let samples: [Payload]
        public let overflow: Bool
        public let more: Bool
        fileprivate let admissionEpoch: UUID
    }
    private let lock = NSLock()
    private var pending: [Payload] = []
    private var scheduled = false
    private var overflow = false
    private var closed = false
    private var admissionEpoch = UUID()
    public init() { pending.reserveCapacity(64) }

    /// True transfers responsibility for scheduling one consumer to caller.
    /// No callback or musical operation occurs under the inbox lock.
    public func submit(_ sample: Payload) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !overflow else { return false }
        if pending.count == 64 {
            overflow = true
            admissionEpoch = UUID()
            pending.removeAll(keepingCapacity:true)
        } else {
            pending.append(sample)
        }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Only the scheduled consumer may drain. Limit each turn so other UI,
    /// stop and release commands can run between batches.
    public func take() -> Batch {
        lock.lock(); defer { lock.unlock() }
        if closed || overflow {
            let fault = overflow && !closed
            pending.removeAll(keepingCapacity:true)
            overflow = false
            scheduled = false
            return .init(samples:[],overflow:fault,more:false,admissionEpoch:admissionEpoch)
        }
        let count = min(16,pending.count)
        let result = Array(pending.prefix(count))
        pending.removeFirst(count)
        let more = !pending.isEmpty
        if !more { scheduled = false }
        return .init(samples:result,overflow:false,more:more,admissionEpoch:admissionEpoch)
    }

    /// Point-in-time check for a previously drained batch. Recheck before
    /// actual sends; this cannot make a transport call atomic with submit.
    public func permits(_ batch: Batch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && !overflow && !batch.overflow && !batch.samples.isEmpty &&
            batch.admissionEpoch == admissionEpoch
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        pending.removeAll()
        overflow = false
        scheduled = false
    }
}
