import Foundation

/// Thread-safe, one-shot receive counter. It admits no data outside the
/// absolute monotonic window, even if the owning actor is stalled.
public final class BoundedMIDIObservation: @unchecked Sendable {
    public struct Counts: Equatable,Sendable {
        public let callbacks:UInt64
        public let packets:UInt64
    }
    private let lock=NSLock()
    private enum State { case idle,active(start:UInt64,deadline:UInt64),retired }
    private var state=State.idle
    private var callbacks:UInt64=0
    private var packets:UInt64=0
    public init() {}
    @discardableResult
    public func begin(now:UInt64,seconds:Int)->Bool {
        lock.lock();defer { lock.unlock() }
        guard case .idle=state,(1...10).contains(seconds) else { return false }
        let (deadline,overflow)=now.addingReportingOverflow(UInt64(seconds)*1_000_000_000)
        guard !overflow else { state = .retired;return false }
        state = .active(start:now,deadline:deadline);return true
    }
    public func record(packets count:UInt32,now:UInt64) {
        lock.lock();defer { lock.unlock() }
        guard case let .active(start,deadline)=state else { return }
        guard now>=start,now<deadline else { state = .retired;return }
        if callbacks<UInt64.max { callbacks+=1 }
        packets+=min(UInt64(count),UInt64.max-packets)
    }
    public func stop()->Counts {
        lock.lock();defer { lock.unlock() }
        state = .retired
        return .init(callbacks:callbacks,packets:packets)
    }
}

/// Main-actor-owned admission ledger for receive-only native sessions.
/// A failed port disposal is ambiguous: never silently free its slot and
/// keep allocating more native ports on the retained process client.
public struct BoundedMIDIObservationSlots:Sendable {
    public static let capacity=4
    private var active:Set<UUID>=[]
    public private(set) var recoveryRequired=false
    public init() {}
    public var count:Int { active.count }
    public mutating func reserve()->UUID? {
        guard !recoveryRequired,active.count<Self.capacity else { return nil }
        let token=UUID()
        guard active.insert(token).inserted else { return nil }
        return token
    }
    @discardableResult
    public mutating func finish(_ token:UUID,portDisposalConfirmed:Bool)->Bool {
        guard active.remove(token) != nil else { return false }
        if !portDisposalConfirmed { recoveryRequired=true }
        return true
    }
}
