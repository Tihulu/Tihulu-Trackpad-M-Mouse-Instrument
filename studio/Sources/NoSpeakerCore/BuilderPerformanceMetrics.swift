/// Aggregate host-side timing; no notes, identities, coordinates or logs.
/// The watchdog's 20 ms cadence is nominal, not an audio deadline.
public struct BuilderPerformanceMetrics: Sendable {
    public private(set) var ticks = 0
    public private(set) var maxTickGap = 0.0
    public private(set) var gapsOver40MS = 0
    public private(set) var maxTickDuration = 0.0
    public private(set) var maxSurfaceQueueAge = 0.0
    public private(set) var commandBatches = 0
    public private(set) var logicalCommands = 0
    public private(set) var midiAttempts = 0
    public private(set) var midiFailures = 0
    public private(set) var maxBatchDuration = 0.0
    private var previousTick: Double?
    public init() {}

    public mutating func recordTick(start: Double, end: Double, oldestSample: Double?) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start,
              previousTick.map({ start >= $0 }) ?? true else { return }
        if let previousTick {
            let gap = start-previousTick
            maxTickGap = max(maxTickGap,gap)
            if gap >= 0.040, gapsOver40MS < Int.max { gapsOver40MS += 1 }
        }
        previousTick = start
        if ticks < Int.max { ticks += 1 }
        maxTickDuration = max(maxTickDuration,end-start)
        if let oldestSample, oldestSample.isFinite, oldestSample >= 0, oldestSample <= start {
            maxSurfaceQueueAge = max(maxSurfaceQueueAge,start-oldestSample)
        }
    }

    public mutating func recordBatch(start: Double, end: Double, commands: Int,
                                     attempts: Int, failures: Int) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start,
              commands > 0, (0...commands).contains(attempts),
              (0...attempts).contains(failures) else { return }
        if commandBatches < Int.max { commandBatches += 1 }
        logicalCommands += min(commands,Int.max-logicalCommands)
        midiAttempts += min(attempts,Int.max-midiAttempts)
        midiFailures += min(failures,Int.max-midiFailures)
        maxBatchDuration = max(maxBatchDuration,end-start)
    }
}
