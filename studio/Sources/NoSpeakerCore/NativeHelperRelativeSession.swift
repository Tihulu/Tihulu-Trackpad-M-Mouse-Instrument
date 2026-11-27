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
    private let maximumAgeNS: Int64?
    private enum Clock { case seconds(Double), nanoseconds(Int64) }
    private let afterAcquisitionNS: Int64
    private var clutch: Clutch
    private var lastSequence: UInt64
    private var lastReceipt: Double?
    private var lastAcquisitionNS: Int64?
    private var lastHostNow: Double?
    private var lastHostNowNS: Int64?
    private var neutralAdmitted = false
    private var active = false
    private var closed = false

    public init?(source: Clutch.Surface, monitor: UUID, registration: UUID, afterSequence: UInt64,
                 afterAcquisitionNS: Int64, maximumAge: Double, lanes: [Clutch.Axis: Clutch.Lane]) {
        guard afterAcquisitionNS >= 0, maximumAge.isFinite, maximumAge > 0,
              let clutch = Clutch(surface: source, lanes: lanes) else { return nil }
        self.source = source; self.monitor = monitor; self.registration = registration
        self.maximumAge = maximumAge; self.maximumAgeNS = nil; self.afterAcquisitionNS = afterAcquisitionNS
        self.clutch = clutch; lastSequence = afterSequence
    }

    /// Native hosts should use one integer clock domain for the entire session.
    /// Double receipts remain only for the existing gesture/smoothing math.
    public init?(source: Clutch.Surface, monitor: UUID, registration: UUID, afterSequence: UInt64,
                 afterAcquisitionNS: Int64, maximumAgeNS: Int64, lanes: [Clutch.Axis: Clutch.Lane]) {
        guard (0..<Int64.max).contains(afterAcquisitionNS), (1..<Int64.max).contains(maximumAgeNS),
              let clutch = Clutch(surface: source, lanes: lanes) else { return nil }
        self.source = source; self.monitor = monitor; self.registration = registration
        self.maximumAge = Double(maximumAgeNS) / 1_000_000_000
        self.maximumAgeNS = maximumAgeNS; self.afterAcquisitionNS = afterAcquisitionNS
        self.clutch = clutch; lastSequence = afterSequence
    }

    private func fresh(_ receipt: Double, acquisitionNS: Int64, now: Clock) -> Bool {
        switch now {
        case .seconds(let seconds):
            return maximumAgeNS == nil && receipt.isFinite && receipt >= 0 && seconds.isFinite &&
                seconds >= receipt && seconds - receipt < maximumAge
        case .nanoseconds(let ns):
            guard let limit = maximumAgeNS, (0..<Int64.max).contains(ns),
                  (0..<Int64.max).contains(acquisitionNS), ns >= acquisitionNS else { return false }
            return ns - acquisitionNS < limit
        }
    }

    /// Impossible future/sentinel observations are not acquisition evidence.
    /// Consume their publication sequence, but never poison the trusted
    /// acquisition/receipt watermarks. Valid expired samples still consume them.
    private func acquisitionPossible(_ acquired: Int64, now: Clock) -> Bool {
        guard (0..<Int64.max).contains(acquired) else { return false }
        switch now {
        case .seconds(let seconds):
            return seconds.isFinite && seconds >= Double(acquired) / 1_000_000_000
        case .nanoseconds(let ns):
            return (0..<Int64.max).contains(ns) && ns >= acquired
        }
    }

    private func matchesClock(_ now: Clock) -> Bool {
        switch now {
        case .seconds: maximumAgeNS == nil
        case .nanoseconds: maximumAgeNS != nil
        }
    }

    /// Keep the trusted high-water mark after faults; equal samples are valid.
    private mutating func observeHostClock(_ now: Clock) -> Bool {
        switch now {
        case .seconds(let seconds):
            guard seconds.isFinite, seconds >= 0, lastHostNow.map({ seconds >= $0 }) ?? true else { return false }
            lastHostNow = seconds
        case .nanoseconds(let ns):
            guard (0..<Int64.max).contains(ns), lastHostNowNS.map({ ns >= $0 }) ?? true else { return false }
            lastHostNowNS = ns
        }
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
        receive(frame, monitor: token, sequence: sequence, clock: .seconds(now), permits: permits,
                activeLeaseValid: activeLeaseValid, begin: begin, move: move, retire: retire)
    }

    public mutating func receive(_ frame: Clutch.SourceFrame, monitor token: UUID,
        sequence: UInt64, nowNS: Int64, permits: () -> Bool, activeLeaseValid: () -> Bool,
        begin: () -> Bool, move: ([Clutch.Axis:Int]) -> Bool,
        retire: (Bool) -> Bool) -> Result {
        receive(frame, monitor: token, sequence: sequence, clock: .nanoseconds(nowNS), permits: permits,
                activeLeaseValid: activeLeaseValid, begin: begin, move: move, retire: retire)
    }

    private mutating func receive(_ frame: Clutch.SourceFrame, monitor token: UUID,
        sequence: UInt64, clock now: Clock, permits: () -> Bool, activeLeaseValid: () -> Bool,
        begin: () -> Bool, move: ([Clutch.Axis:Int]) -> Bool,
        retire: (Bool) -> Bool) -> Result {
        guard !closed, token == monitor, frame.surface == source else { return .ignored }
        guard sequence > lastSequence else { return .ignored }
        lastSequence = sequence
        guard matchesClock(now) else { return close(retire: retire) }
        let clockValid = observeHostClock(now)
        // Same monitor but a changed native registration is a terminal
        // device-identity boundary, not an ordinary lift or new touch.
        guard frame.nativeRegistration == registration else {
            closed = true
            return fault(retire: retire)
        }
        guard let acquired = frame.acquisitionNS, acquired > afterAcquisitionNS,
              acquisitionPossible(acquired, now: now),
              lastAcquisitionNS.map({ acquired > $0 }) ?? true else { return fault(retire: retire) }
        let previousAcquisition = lastAcquisitionNS
        lastAcquisitionNS = acquired
        guard frame.receipt == Double(acquired) / 1_000_000_000 else { return fault(retire: retire) }
        let previous = lastReceipt
        guard previous.map({ frame.receipt > $0 }) ?? true else { return fault(retire: retire) }
        lastReceipt = frame.receipt
        guard clockValid, fresh(frame.receipt, acquisitionNS: acquired, now: now), permits(), (!active || activeLeaseValid()) else { return fault(retire: retire) }
        // A new fresh sample cannot hide an expired active stream if the
        // watchdog was delayed. Even a neutral sample after a gap must be
        // processed on a later call, not on the expiry boundary itself.
        if active, let previous, let previousAcquisition, !fresh(previous, acquisitionNS: previousAcquisition, now: now) { return fault(retire: retire) }
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
            // A valid held contact can be unchanged after quantization or
            // saturation. Report active admission without a redundant send.
            return active ? .accepted : .waiting
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
    public mutating func expire(now: Double, activeLeaseValid: () -> Bool = { true },
                                retire: (Bool) -> Bool) -> Result {
        expire(clock: .seconds(now), activeLeaseValid: activeLeaseValid, retire: retire)
    }

    public mutating func expire(nowNS: Int64, activeLeaseValid: () -> Bool = { true },
                                retire: (Bool) -> Bool) -> Result {
        expire(clock: .nanoseconds(nowNS), activeLeaseValid: activeLeaseValid, retire: retire)
    }

    private mutating func expire(clock now: Clock, activeLeaseValid: () -> Bool,
                                 retire: (Bool) -> Bool) -> Result {
        guard !closed else { return .ignored }
        guard matchesClock(now) else { return close(retire: retire) }
        guard observeHostClock(now) else {
            // Revoke even a silent neutral admission, but do not retry
            // cleanup on every subsequent bad idle watchdog sample.
            guard active || neutralAdmitted else { return .ignored }
            return fault(retire: retire)
        }
        guard active else { return .ignored }
        // An active lease can be preempted while the device is silent.
        // Check it on the existing serialized watchdog, not just on frames.
        guard activeLeaseValid() else { return fault(retire: retire) }
        guard let receipt = lastReceipt, let acquired = lastAcquisitionNS,
              !fresh(receipt, acquisitionNS: acquired, now: now) else { return .ignored }
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
