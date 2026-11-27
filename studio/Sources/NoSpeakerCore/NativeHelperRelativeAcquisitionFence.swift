import Foundation

/// A frozen selected-source boundary sampled under the producer's publication
/// lock. The host separately retains its consumer monitor/queue identity.
/// Neither construction nor a cached empty preview authorizes MIDI output.
public struct NativeHelperRelativeArmBoundary: Sendable {
    public typealias Clutch = NativeHelperRelativeClutch
    public let source: Clutch.Surface
    public let registration: UUID
    public let afterSequence: UInt64
    public let afterAcquisitionNS: Int64

    public init?(source: Clutch.Surface, registration: UUID, afterSequence: UInt64,
                 afterAcquisitionNS: Int64) {
        guard afterSequence < UInt64.max, (0..<Int64.max).contains(afterAcquisitionNS) else { return nil }
        self.source = source; self.registration = registration
        self.afterSequence = afterSequence; self.afterAcquisitionNS = afterAcquisitionNS
    }

    /// Construct exactly once for an admitted source-local observation.
    /// Reuse this fence across all synchronous checks for that observation.
    /// A rejected selected-source fence must reach session retirement, not
    /// be silently dropped or converted to a genuine neutral observation.
    public func fence(for frame: Clutch.SourceFrame, sequence: UInt64) -> NativeHelperRelativeAcquisitionFence {
        let acquired = frame.acquisitionNS
        let valid = frame.surface == source && frame.nativeRegistration == registration &&
            sequence > afterSequence && frame.isComplete &&
            (acquired.map { $0 > afterAcquisitionNS && $0 < Int64.max &&
                frame.receipt == Double($0) / 1_000_000_000 } ?? false)
        return .init(acquisitionNS: acquired, valid: valid)
    }
}

/// Per-observation original callback receipt gate; never use the later queue
/// publication time as its clock. The same existing physical input age limit
/// applies. This gate is for onsets/admission, not emergency release sends.
public struct NativeHelperRelativeAcquisitionFence: Sendable {
    public static let maximumAgeNS = Int64((TouchPublicationAdmission.maximumAge * 1_000_000_000).rounded(.down))
    private let acquisitionNS: Int64?
    private var lastNowNS: Int64?
    public private(set) var rejected: Bool

    fileprivate init(acquisitionNS: Int64?, valid: Bool) {
        self.acquisitionNS = acquisitionNS; rejected = !valid
    }

    /// The host must evaluate live monitor/queue/registration/configuration
    /// admission on every call, and read the original monotonic clock anew.
    /// A failed permit cannot recover within this observation, even if the
    /// clock or external permit later appears healthy again.
    public mutating func permits(nowNS: Int64, live: Bool) -> Bool {
        guard !rejected, live, let acquisitionNS,
              (0..<Int64.max).contains(nowNS), nowNS >= acquisitionNS,
              lastNowNS.map({ nowNS >= $0 }) ?? true,
              nowNS - acquisitionNS < Self.maximumAgeNS else {
            rejected = true
            return false
        }
        lastNowNS = nowNS
        return true
    }
}
