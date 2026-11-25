import Testing
@testable import NoSpeakerCore

@Test func touchPreviewCadenceLimitsVisualUpdatesOnly() {
    var gate = TouchPreviewCadence()
    #expect(gate.permits(now:0,cleared:false))
    #expect(!gate.permits(now:0.005,cleared:false))
    #expect(!gate.permits(now:0.015,cleared:false))
    #expect(gate.permits(now:0.017,cleared:false))
    #expect(gate.permits(now:0.018,cleared:true))
    #expect(!gate.permits(now:0.019,cleared:false))
    gate.reset()
    #expect(gate.permits(now:0.019,cleared:false))
}

@Test func touchPreviewCadenceHandlesClockResetAndInvalidValues() {
    var gate = TouchPreviewCadence()
    #expect(!gate.permits(now:.nan,cleared:true))
    #expect(!gate.permits(now:.infinity,cleared:false))
    #expect(!gate.permits(now:-1,cleared:false))
    #expect(gate.permits(now:1,cleared:false))
    #expect(gate.permits(now:0,cleared:false))
    #expect(!gate.permits(now:0.001,cleared:false))
}

@Test func touchPreviewCadenceBoundsHighRateMotion() {
    var gate = TouchPreviewCadence()
    let count = (0..<1000).filter { gate.permits(now:Double($0)/1000,cleared:false) }.count
    #expect(count <= 60)
    #expect(count >= 50)
}
