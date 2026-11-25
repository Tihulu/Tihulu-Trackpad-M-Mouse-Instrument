/// Aggregate monotonic timing only, no coordinates, notes or per-frame logs.
public struct TouchDispatchMetrics: Sendable {
    public private(set) var count = 0
    public private(set) var rejected = 0
    public private(set) var queueMean = 0.0
    public private(set) var queueMax = 0.0
    public private(set) var processingMean = 0.0
    public private(set) var processingMax = 0.0
    public private(set) var queueOver10ms = 0
    public init() {}
    public mutating func reject() { if rejected < Int.max { rejected += 1 } }
    public mutating func record(queuedAt: Double, startedAt: Double, endedAt: Double) {
        guard queuedAt.isFinite, startedAt.isFinite, endedAt.isFinite,
              queuedAt >= 0, startedAt >= queuedAt, endedAt >= startedAt,
              count < Int.max else { return }
        let queue = startedAt - queuedAt, processing = endedAt - startedAt
        count += 1
        queueMean += (queue - queueMean) / Double(count)
        processingMean += (processing - processingMean) / Double(count)
        queueMax = max(queueMax, queue)
        processingMax = max(processingMax, processing)
        if queue >= 0.010 { queueOver10ms += 1 }
    }
}
