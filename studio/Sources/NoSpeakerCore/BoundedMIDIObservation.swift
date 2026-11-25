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
