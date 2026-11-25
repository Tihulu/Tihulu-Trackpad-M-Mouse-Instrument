import Testing
@testable import NoSpeakerCore

@Test func builderTimingMeasuresWatchdogGapAndOldestSurfaceAge() {
    var m = BuilderPerformanceMetrics()
    m.recordTick(start:1,end:1.002,oldestSample:0.99)
    m.recordTick(start:1.02,end:1.024,oldestSample:1.018)
    m.recordTick(start:1.08,end:1.081,oldestSample:1.03)
    #expect(m.ticks == 3)
    #expect(m.gapsOver40MS == 1)
    #expect(abs(m.maxTickGap-0.06) < 0.000001)
    #expect(abs(m.maxTickDuration-0.004) < 0.000001)
    #expect(abs(m.maxSurfaceQueueAge-0.05) < 0.000001)
    m.recordTick(start:0,end:1,oldestSample:nil)
    m.recordTick(start:.nan,end:1,oldestSample:nil)
    #expect(m.ticks == 3)
}

@Test func builderBatchMetricsDistinguishLogicalCommandsFromMIDIAndFailures() {
    var m = BuilderPerformanceMetrics()
    m.recordBatch(start:1,end:1.001,commands:4,attempts:0,failures:0)
    m.recordBatch(start:2,end:2.006,commands:5,attempts:3,failures:1)
    m.recordBatch(start:2,end:3,commands:1,attempts:2,failures:0)
    m.recordBatch(start:3,end:2,commands:1,attempts:1,failures:0)
    #expect(m.commandBatches == 2)
    #expect(m.logicalCommands == 9)
    #expect(m.midiAttempts == 3)
    #expect(m.midiFailures == 1)
    #expect(abs(m.maxBatchDuration-0.006) < 0.000001)
}

@Test func builderMetricsCountersSaturateAndResetWithoutOverflow() {
    var m = BuilderPerformanceMetrics()
    m.recordBatch(start:1,end:1,commands:Int.max,attempts:Int.max,failures:Int.max)
    m.recordBatch(start:2,end:2,commands:1,attempts:1,failures:1)
    #expect(m.logicalCommands == Int.max)
    #expect(m.midiAttempts == Int.max)
    #expect(m.midiFailures == Int.max)
    m = BuilderPerformanceMetrics()
    #expect(m.commandBatches == 0 && m.logicalCommands == 0 && m.midiAttempts == 0)
}
