import Testing
@testable import NoSpeakerCore

@Test func groupTimingDiagnosticsDistinguishesSchedulingGapsAndWork() {
    var metrics = PerformanceGroupTimingDiagnostics()
    metrics.record(start:1,end:1.01)
    metrics.record(start:1.02,end:1.024)
    metrics.record(start:1.23,end:1.26)
    metrics.record(start:1.64,end:1.65)
    #expect(metrics.cycles == 4)
    #expect(metrics.gapsAtLeast100MS == 2)
    #expect(metrics.gapsAtLeast350MS == 1)
    #expect(abs(metrics.peakGapMS-410) < 0.001)
    #expect(abs(metrics.peakWorkMS-30) < 0.001)
}
@Test func groupTimingDiagnosticsInvalidSamplesDoNotRenewClock() {
    var metrics = PerformanceGroupTimingDiagnostics()
    metrics.record(start:1,end:1)
    metrics.record(start:0.5,end:0.6)
    metrics.record(start:2,end:1)
    metrics.record(start:.nan,end:2)
    metrics.record(start:2,end:.infinity)
    metrics.record(start:1.5,end:1.51)
    #expect(metrics.invalidSamples == 4)
    #expect(metrics.cycles == 2)
    #expect(metrics.gapsAtLeast350MS == 1)
    #expect(metrics.peakGapMS == 500)
}

@Test func groupTimingDiagnosticsIncludesNominalDeadlineBoundaries() {
    var hundred = PerformanceGroupTimingDiagnostics()
    hundred.record(start:1.1,end:1.1)
    hundred.record(start:1.2,end:1.2)
    #expect(hundred.gapsAtLeast100MS == 1)
    var threeFifty = PerformanceGroupTimingDiagnostics()
    threeFifty.record(start:1.1,end:1.1)
    threeFifty.record(start:1.45,end:1.45)
    #expect(threeFifty.gapsAtLeast350MS == 1)
}

@Test func groupTimingDiagnosticsDoesNotCountOneNanosecondEarlyGaps() {
    var hundred = PerformanceGroupTimingDiagnostics()
    hundred.record(start:1.1,end:1.1)
    hundred.record(start:1.199999999,end:1.199999999)
    #expect(hundred.gapsAtLeast100MS == 0)
    var threeFifty = PerformanceGroupTimingDiagnostics()
    threeFifty.record(start:1.1,end:1.1)
    threeFifty.record(start:1.449999999,end:1.449999999)
    #expect(threeFifty.gapsAtLeast350MS == 0)
}
