import Foundation

/// Host-local reservation for exclusively owned MIDI endpoints. This is not
/// a CoreMIDI registration API. One serialized host must share this registry
/// across all custom-pad producers and exclude other producers independently.
/// The supplied incarnation must identify the original physical/virtual
/// object, not merely its reusable numeric ID. Callbacks must not reenter.
public final class CustomSurfaceEndpointReservations {
    public struct Lease: Equatable, Sendable {
        public let endpointID: Int32
        public let incarnation: UUID
        fileprivate let token: UUID
    }
    private struct Session {
        let lease: Lease
        let delivery: CustomSurfaceExclusiveDelivery
    }
    private var sessions: [Int32: Session] = [:]
    public init() {}
    public var reservedIDs: Set<Int32> { Set(sessions.keys) }

    /// Refuse an occupied ID, even if the caller offers a new incarnation.
    /// The registry strongly retains its ledger until explicit clean close.
    public func open(endpointID: Int32, incarnation: UUID,
                     plan: CustomSurfaceMixedPlan, permitsNeutralSilence: Bool = false, clock: @escaping () -> Int64,
                     admitsLive: @escaping () -> Bool,
                     ownsEndpoint: @escaping (Int32, UUID) -> Bool,
                     send: @escaping (Int32, UUID, SensorCommand) -> Bool) -> Lease? {
        guard endpointID != 0, sessions[endpointID] == nil,
              ownsEndpoint(endpointID, incarnation), admitsLive() else { return nil }
        let lease = Lease(endpointID: endpointID, incarnation: incarnation, token: UUID())
        let delivery = CustomSurfaceExclusiveDelivery(plan: plan, permitsNeutralSilence: permitsNeutralSilence, clock: clock,
            admitsExclusiveEndpoint: admitsLive,
            ownsCleanupEndpoint: { ownsEndpoint(endpointID, incarnation) },
            send: { send(endpointID, incarnation, $0) })
        sessions[endpointID] = Session(lease: lease, delivery: delivery)
        return lease
    }

    private func session(_ lease: Lease) -> Session? {
        guard let session = sessions[lease.endpointID], session.lease == lease else { return nil }
        return session
    }
    public func frame(_ lease: Lease, contacts: [CustomSurfaceContactProjection.Contact],
                      sequence: UInt64, observedAt: Int64) -> CustomSurfaceExclusiveDelivery.Report? {
        session(lease)?.delivery.frame(contacts, sequence: sequence, observedAt: observedAt)
    }
    public func poll(_ lease: Lease) -> CustomSurfaceExclusiveDelivery.Report? {
        session(lease)?.delivery.poll()
    }
    /// A failed close retains both reservation and cleanup debt. An old
    /// lease must never affect a later session with the same endpoint ID.
    public func close(_ lease: Lease) -> CustomSurfaceExclusiveDelivery.Report? {
        guard let session = session(lease) else { return nil }
        let report = session.delivery.stop()
        if report.retired && report.outstanding.isEmpty {
            sessions.removeValue(forKey: lease.endpointID)
        }
        return report
    }
    /// Retry only retired output. A live session cannot be released by retry.
    public func retryCleanup(_ lease: Lease) -> CustomSurfaceExclusiveDelivery.Report? {
        guard let session = session(lease) else { return nil }
        let report = session.delivery.retryCleanup()
        if report.retired && report.outstanding.isEmpty {
            sessions.removeValue(forKey: lease.endpointID)
        }
        return report
    }
}
