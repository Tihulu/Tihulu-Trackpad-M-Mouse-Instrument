import Testing
@testable import NoSpeakerCore

@Test func touchDispatchMetricsSeparatesQueueFromProcessing() {
    var metrics = TouchDispatchMetrics()
    metrics.record(queuedAt:0,startedAt:0.004,endedAt:0.006)
    metrics.record(queuedAt:1,startedAt:1.016,endedAt:1.020)
    metrics.reject()
    #expect(metrics.count == 2)
    #expect(metrics.rejected == 1)
    #expect(abs(metrics.queueMean-0.010) < 0.000001)
    #expect(abs(metrics.queueMax-0.016) < 0.000001)
    #expect(abs(metrics.processingMean-0.003) < 0.000001)
    #expect(abs(metrics.processingMax-0.004) < 0.000001)
    #expect(metrics.queueOver10ms == 1)
}

@Test func touchDispatchMetricsRejectsInvalidTimesWithoutCorruptingTotals() {
    var metrics = TouchDispatchMetrics()
    for value in [Double.nan, .infinity, -.infinity, -1] {
        metrics.record(queuedAt:value,startedAt:0,endedAt:1)
    }
    metrics.record(queuedAt:2,startedAt:1,endedAt:3)
    metrics.record(queuedAt:1,startedAt:3,endedAt:2)
    #expect(metrics.count == 0)
    #expect(metrics.queueMax == 0)
    #expect(metrics.processingMax == 0)
    metrics.record(queuedAt:1,startedAt:1,endedAt:1)
    #expect(metrics.count == 1)
    #expect(metrics.queueMean == 0)
}
