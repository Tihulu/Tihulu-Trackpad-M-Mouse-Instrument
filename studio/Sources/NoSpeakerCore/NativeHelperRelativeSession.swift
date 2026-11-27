import Foundation

/// Source-bound session adapter. The host owns the actual monotonic clock,
/// admission fence, orientation transform, and serialized MIDI transport.
/// No reference or MIDI output is invented here.
public struct NativeHelperRelativeSession: Sendable {
    public typealias Clutch = NativeHelperRelativeClutch
    public enum Result: Equatable, Sendable {
        case ignored, waiting, anchored, accepted, retired
    }
    private let source: Clutch.Surface
    private let monitor: UUID
    private let registration: UUID
    private let maximumAge: Double
    private let afterAcquisitionNS: Int64
    private var clutch: Clutch
    private var lastSequence: UInt64
    private var lastReceipt: Double?
    private var lastAcquisitionNS: Int64?
    private var lastHostNow: Double?
    private var neutralAdmitted = false
    private var active = false
    private var closed = false

    public init?(source: Clutch.Surface, monitor: UUID, registration: UUID, afterSequence: UInt64,
                 afterAcquisitionNS: Int64, maximumAge: Double, lanes: [Clutch.Axis: Clutch.Lane]) {
        guard afterAcquisitionNS >= 0, maximumAge.isFinite, maximumAge > 0,
              let clutch = Clutch(surface: source, lanes: lanes) else { return nil }
        self.source = source; self.monitor = monitor; self.registration = registration
        self.maximumAge = maximumAge; self.afterAcquisitionNS = afterAcquisitionNS
        self.clutch = clutch; lastSequence = afterSequence
    }

    private func fresh(_ receipt: Double, now: Double) -> Bool {
        receipt.isFinite && receipt >= 0 && now.isFinite && now >= receipt && now - receipt < maximumAge
    }

    /// A fresh receipt alone cannot prove that the trusted host clock has
    /// advanced since a previous observation or watchdog tick. Keep the
    /// high-water mark even after a fault; equal clock samples are valid.
    private mutating func observeHostClock(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastHostNow.map({ now >= $0 }) ?? true else { return false }
        lastHostNow = now
        return true
    }

    private mutating func fault(retire: (Bool) -> Bool) -> Result {
        _ = clutch.invalidate(); active = false; neutralAdmitted = false
        _ = retire(false)
        return .retired
    }

    /// Caller must supply original source-local observation (not a cached
    /// combined preview) and the actual producer monitor/sequence identity.
    /// The admission callback must recheck the live receipt before each send.
    public mutating func receive(_ frame: Clutch.SourceFrame, monitor token: UUID,
        sequence: UInt64, now: Double, permits: () -> Bool, activeLeaseValid: () -> Bool,
        begin: () -> Bool, move: ([Clutch.Axis:Int]) -> Bool,
        retire: (Bool) -> Bool) -> Result {
        guard !closed, token == monitor, frame.surface == source else { return .ignored }
        guard sequence > lastSequence else { return .ignored }
        lastSequence = sequence
        let clockValid = observeHostClock(now)
        // Same monitor but a changed native registration is a terminal
        // device-identity boundary, not an ordinary lift or new touch.
        guard frame.nativeRegistration == registration else {
            closed = true
            return fault(retire: retire)
        }
        guard let acquired = frame.acquisitionNS, acquired > afterAcquisitionNS,
              lastAcquisitionNS.map({ acquired > $0 }) ?? true else { return fault(retire: retire) }
        lastAcquisitionNS = acquired
        guard frame.receipt == Double(acquired) / 1_000_000_000 else { return fault(retire: retire) }
        let previous = lastReceipt
        guard previous.map({ frame.receipt > $0 }) ?? true else { return fault(retire: retire) }
        lastReceipt = frame.receipt
        guard clockValid, fresh(frame.receipt, now: now), permits(), (!active || activeLeaseValid()) else { return fault(retire: retire) }
        // A new fresh sample cannot hide an expired active stream if the
        // watchdog was delayed. Even a neutral sample after a gap must be
        // processed on a later call, not on the expiry boundary itself.
        if active, let previous, !fresh(previous, now: now) { return fault(retire: retire) }
        let result = clutch.frame(frame)
        switch result {
        case .blocked:
            neutralAdmitted = false
            if active { return fault(retire: retire) }
            return .waiting
        case .releaseRequired, .idle:
            if frame.isGenuineNeutral {
                active = false
                guard retire(true), permits() else { return fault(retire: retire) }
                neutralAdmitted = true
                return .waiting
            }
            if result == .releaseRequired { return fault(retire: retire) }
            return .waiting
        case .anchored:
            guard permits(), begin(), permits(), activeLeaseValid() else { return fault(retire: retire) }
            neutralAdmitted = false; active = true
            return .anchored
        case .movement(let values):
            guard active, permits(), activeLeaseValid(), move(values), permits(), activeLeaseValid() else { return fault(retire: retire) }
            return .accepted
        }
    }

    /// The host schedules this on the same serialized execution context.
    /// Never use an absent or stale sample as neutral evidence.
    public mutating func expire(now: Double, retire: (Bool) -> Bool) -> Result {
        guard !closed else { return .ignored }
        guard observeHostClock(now) else {
            // Revoke even a silent neutral admission, but do not retry
            // cleanup on every subsequent bad idle watchdog sample.
            guard active || neutralAdmitted else { return .ignored }
            return fault(retire: retire)
        }
        guard active, let receipt = lastReceipt, !fresh(receipt, now: now) else { return .ignored }
        return fault(retire: retire)
    }

    /// Explicit stop, configuration or monitor change permanently closes
    /// this session. Only a new session plus real neutral can arm again.
    public mutating func close(retire: (Bool) -> Bool) -> Result {
        guard !closed else { return .ignored }
        closed = true
        return fault(retire: retire)
    }
}
