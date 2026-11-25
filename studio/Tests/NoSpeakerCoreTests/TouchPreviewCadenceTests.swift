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

@Test func previewCadencePreservesContactEdgesBetweenMovementTicks() {
    var gate = TouchPreviewCadence()
    let first = gate.permits(now:1,cleared:false)
    #expect(first)
    let secondFinger = gate.permits(now:1.001,cleared:false,contactEdge:true)
    #expect(secondFinger)
    let move = gate.permits(now:1.002,cleared:false)
    #expect(!move)
    let lift = gate.permits(now:1.003,cleared:false,contactEdge:true)
    #expect(lift)
    let clear = gate.permits(now:1.004,cleared:true)
    #expect(clear)
    let retrigger = gate.permits(now:1.005,cleared:false,contactEdge:true)
    #expect(retrigger)
    let invalid = gate.permits(now:.nan,cleared:false,contactEdge:true)
    #expect(!invalid)
}
