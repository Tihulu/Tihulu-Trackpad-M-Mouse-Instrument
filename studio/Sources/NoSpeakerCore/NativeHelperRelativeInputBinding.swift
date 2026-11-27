import Foundation

/// A single explicitly armed source and immutable manual configuration.
/// The serialized host owns the transport, monitor lifetime and watchdog.
/// Never route legacy aggregate contacts through this binding.
public struct NativeHelperRelativeInputBinding: Sendable {
    public typealias Clutch = NativeHelperRelativeClutch
    public typealias Result = NativeHelperRelativeSession.Result
    public let boundary: NativeHelperRelativeArmBoundary
    public let monitor: UUID
    public let plan: NativeHelperRelativeOutputPlan
    private let orientation: NativeHelperRelativeOrientation
    private var session: NativeHelperRelativeSession

    public init?(boundary: NativeHelperRelativeArmBoundary, monitor: UUID,
                 configuration: NativeHelperRelativeSingleChannel, orientation: SurfaceOrientation) {
        guard let session = NativeHelperRelativeSession(source: boundary.source, monitor: monitor,
            registration: boundary.registration, afterSequence: boundary.afterSequence,
            afterAcquisitionNS: boundary.afterAcquisitionNS, maximumAge: TouchPublicationAdmission.maximumAge,
            lanes: configuration.configuration.lanes) else { return nil }
        self.boundary = boundary; self.monitor = monitor; self.session = session
        self.plan = configuration.configuration.plan
        self.orientation = .init(selectedSurface: boundary.source, magicMouseOrientation: orientation)
    }

    /// Pass the same fresh admission closure to each actual send. Lease
    /// validation is separate and is sampled outside staged transport writes.
    /// All neutral callbacks use the frozen plan, including before anchor.
    public mutating func receive(_ frame: Clutch.SourceFrame?, source: Clutch.Surface,
        monitor token: UUID, sequence: UInt64, clock: @escaping () -> Int64, live: @escaping () -> Bool,
        activeLeaseValid: () -> Bool,
        begin: (NativeHelperRelativeOutputPlan, () -> Bool) -> Bool,
        move: ([Clutch.Axis: Int], () -> Bool) -> Bool,
        retire: (Bool, NativeHelperRelativeOutputPlan) -> Bool) -> Result {
        guard token == monitor, source == boundary.source else { return .ignored }
        let frozenPlan = plan
        guard let frame, frame.surface == source else {
            return session.close(retire: { retire($0, frozenPlan) })
        }
        var fence = boundary.fence(for: frame, sequence: sequence)
        func permits() -> Bool {
            let admitted = live()
            return fence.permits(nowNS: clock(), live: admitted)
        }
        return session.receive(orientation.project(frame), monitor: token, sequence: sequence,
            now: Double(clock()) / 1_000_000_000, permits: permits, activeLeaseValid: activeLeaseValid,
            begin: { begin(frozenPlan, permits) }, move: { move($0, permits) },
            retire: { retire($0, frozenPlan) })
    }

    /// Call even without frames. Loss of the source/host is terminal; an
    /// ordinary stream expiry retires the clutch without inventing a lift.
    public mutating func poll(nowNS: Int64, live: Bool,
        retire: (Bool, NativeHelperRelativeOutputPlan) -> Bool) -> Result {
        let frozenPlan = plan
        guard live, (0..<Int64.max).contains(nowNS) else {
            return session.close(retire: { retire($0, frozenPlan) })
        }
        return session.expire(now: Double(nowNS) / 1_000_000_000,
                              retire: { retire($0, frozenPlan) })
    }

    /// No live-admission gate on cleanup. The service owns any unresolved
    /// debt after the binding is closed; never recreate it to bypass debt.
    public mutating func close(retire: (Bool, NativeHelperRelativeOutputPlan) -> Bool) -> Result {
        let frozenPlan = plan
        return session.close(retire: { retire($0, frozenPlan) })
    }
}
