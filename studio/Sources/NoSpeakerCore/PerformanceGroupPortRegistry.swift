import Foundation

/// Transactional endpoint registration only. No MIDI sending or hardware activation.
public struct PerformanceGroupPortRegistry: Sendable {
    public enum Lookup: Equatable, Sendable {
        case absent, present(UInt32), unavailable
    }
    public struct Creation: Sendable {
        public let handle: UInt32
        public let succeeded: Bool
        public init(handle: UInt32, succeeded: Bool) {
            self.handle = handle; self.succeeded = succeeded
        }
    }
    public enum Failure: Error, Equatable {
        case busy, recoveryRequired, occupied(Int32), lookupFailed(Int32)
        case createFailed(UUID), assignFailed(UUID), verifyFailed(UUID)
    }
    private var plan: PerformanceGroupEndpointPlan?
    private var registered: [UUID: UInt32] = [:]
    private var quarantine: Set<UInt32> = []
    public init() {}
    public var registeredIDs: Set<UUID> { Set(registered.keys) }
    public var pendingDisposalCount: Int { quarantine.count }
    public var hasRecoveryDebt: Bool { !quarantine.isEmpty }

    public func handle(for group: UUID) -> UInt32? { registered[group] }

    /// Verify all identities before opening, then verify each assignment by
    /// looking it up again. The backend must serialize calls and return only
    /// newly created, owned nonzero handles from create().
    public mutating func open(_ requested: PerformanceGroupEndpointPlan,
                              lookup: (Int32) -> Lookup,
                              create: (PerformanceGroupEndpointPlan.Entry) -> Creation,
                              assign: (UInt32, Int32) -> Bool,
                              dispose: (UInt32) -> Bool) throws {
        guard quarantine.isEmpty else { throw Failure.recoveryRequired }
        if let plan {
            guard plan == requested else { throw Failure.busy }
            for entry in plan.entries {
                guard let handle = registered[entry.id],
                      lookup(entry.uniqueID) == .present(handle) else {
                    throw Failure.verifyFailed(entry.id)
                }
            }
            return
        }
        for entry in requested.entries {
            switch lookup(entry.uniqueID) {
            case .absent: break
            case .present: throw Failure.occupied(entry.uniqueID)
            case .unavailable: throw Failure.lookupFailed(entry.uniqueID)
            }
        }

        var staged: [UUID:UInt32] = [:]
        var created: [UInt32] = []
        do {
            for entry in requested.entries {
                let result = create(entry)
                guard result.handle != 0, !created.contains(result.handle) else {
                    throw Failure.createFailed(entry.id)
                }
                created.append(result.handle)
                guard result.succeeded else { throw Failure.createFailed(entry.id) }
                // A newly created source may already have the requested ID.
                // Never claim an ID occupied by a different object.
                switch lookup(entry.uniqueID) {
                case .absent: break
                case .present(let handle) where handle == result.handle: break
                case .present: throw Failure.occupied(entry.uniqueID)
                case .unavailable: throw Failure.lookupFailed(entry.uniqueID)
                }
                guard assign(result.handle,entry.uniqueID) else { throw Failure.assignFailed(entry.id) }
                guard lookup(entry.uniqueID) == .present(result.handle) else {
                    throw Failure.verifyFailed(entry.id)
                }
                staged[entry.id] = result.handle
            }
        } catch {
            for handle in created.reversed() where !dispose(handle) {
                quarantine.insert(handle)
            }
            throw error
        }
        registered = staged
        plan = requested
    }

    /// The host must first complete all MIDI cleanup. A refused close never
    /// disposes an endpoint. Failed disposals remain quarantined for retry.
    @discardableResult
    public mutating func close(cleanupComplete: Bool, dispose: (UInt32) -> Bool) -> Bool {
        guard cleanupComplete else { return false }
        let handles = registered.values.sorted()
        registered.removeAll()
        plan = nil
        for handle in handles where !dispose(handle) { quarantine.insert(handle) }
        return quarantine.isEmpty
    }

    @discardableResult
    public mutating func retryDisposal(_ dispose: (UInt32) -> Bool) -> Bool {
        for handle in quarantine.sorted() where dispose(handle) { quarantine.remove(handle) }
        return quarantine.isEmpty
    }
}
