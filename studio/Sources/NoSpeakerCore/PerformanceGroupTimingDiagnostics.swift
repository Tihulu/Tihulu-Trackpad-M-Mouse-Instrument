import Foundation

/// Aggregate host scheduling evidence, not audio or receiver latency.
/// Constant storage; no per-event logging, identifiers or wall-clock time.
/// Diagnostics never change admission, expiry, or scheduling policy.
public struct PerformanceGroupTimingDiagnostics: Equatable, Sendable {
    public private(set) var cycles = 0
    public private(set) var invalidSamples = 0
    public private(set) var gapsAtLeast100MS = 0
    public private(set) var gapsAtLeast350MS = 0
    public private(set) var peakGapMS = 0.0
    public private(set) var peakWorkMS = 0.0
    private var previousStart:Double?
    public init() {}

    public mutating func record(start:Double,end:Double) {
        guard start.isFinite,end.isFinite,start >= 0,end >= start,
              previousStart.map({ start >= $0 }) ?? true,
              ((end-start)*1000).isFinite,
              previousStart.map({ ((start-$0)*1000).isFinite }) ?? true else {
            if invalidSamples < Int.max { invalidSamples += 1 }
            return
        }
        if let previousStart {
            let gap = (start-previousStart)*1000
            peakGapMS = max(peakGapMS,gap)
            // Timestamp conversion and subtraction can land just below an
            // exact boundary. Classify the diagnostic gap at nearest-ns
            // precision (half a nanosecond in milliseconds), without
            // changing the reported peak or any live admission deadline.
            let halfNSInMS = 0.0000005
            if gap >= 100-halfNSInMS,gapsAtLeast100MS < Int.max { gapsAtLeast100MS += 1 }
            if gap >= 350-halfNSInMS,gapsAtLeast350MS < Int.max { gapsAtLeast350MS += 1 }
        }
        peakWorkMS = max(peakWorkMS,(end-start)*1000)
        previousStart = start
        if cycles < Int.max { cycles += 1 }
    }
}
