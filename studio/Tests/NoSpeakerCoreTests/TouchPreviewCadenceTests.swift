import Testing
@testable import NoSpeakerCore

@Test func touchPreviewCadenceLimitsVisualUpdatesOnly() {
    var gate = TouchPreviewCadence()
    do {
        let allowed = gate.permits(now:0,cleared:false)
        #expect(allowed)
    }
    do {
        let allowed = gate.permits(now:0.005,cleared:false)
        #expect(!allowed)
    }
    do {
        let allowed = gate.permits(now:0.015,cleared:false)
        #expect(!allowed)
    }
    do {
        let allowed = gate.permits(now:0.017,cleared:false)
        #expect(allowed)
    }
    do {
        let allowed = gate.permits(now:0.018,cleared:true)
        #expect(allowed)
    }
    do {
        let allowed = gate.permits(now:0.019,cleared:false)
        #expect(!allowed)
    }
    gate.reset()
    do {
        let allowed = gate.permits(now:0.019,cleared:false)
        #expect(allowed)
    }
}

@Test func touchPreviewCadenceHandlesClockResetAndInvalidValues() {
    var gate = TouchPreviewCadence()
    do {
        let allowed = gate.permits(now:.nan,cleared:true)
        #expect(!allowed)
    }
    do {
        let allowed = gate.permits(now:.infinity,cleared:false)
        #expect(!allowed)
    }
    do {
        let allowed = gate.permits(now:-1,cleared:false)
        #expect(!allowed)
    }
    do {
        let allowed = gate.permits(now:1,cleared:false)
        #expect(allowed)
    }
    do {
        let allowed = gate.permits(now:0,cleared:false)
        #expect(allowed)
    }
    do {
        let allowed = gate.permits(now:0.001,cleared:false)
        #expect(!allowed)
    }
}

@Test func touchPreviewCadenceBoundsHighRateMotion() {
    var gate = TouchPreviewCadence()
    let count = (0..<1000).filter { gate.permits(now:Double($0)/1000,cleared:false) }.count
    #expect(count <= 60)
    #expect(count >= 50)
}
