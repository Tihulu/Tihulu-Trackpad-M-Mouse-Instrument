import Testing
@testable import NoSpeakerCore

@Test(arguments: [0.0, 100.0, 10_000.0], [0.25, 0.5, 1.0, 2.0])
func invalidTapDoesNotCorruptTempoHistory(origin: Double, interval: Double) {
    var reference = TapTempo()
    var candidate = TapTempo()
    let invalidInitial: [Double] = [-1, -0.25, -.infinity, .infinity, .nan]
    for invalid in invalidInitial {
        #expect(candidate.tap(at: invalid) == nil)
    }
    for index in 0..<12 {
        let time = origin + Double(index) * interval
        #expect(candidate.tap(at: time) == reference.tap(at: time))
        for invalid in [time, time - 0.125, time - 5, -1, -.infinity, .infinity, .nan] {
            #expect(candidate.tap(at: invalid) == nil)
        }
    }
}

@Test func tapTempoRetainsPositiveGapResetAndRollingWindow() {
    var tempo = TapTempo()
    #expect(tempo.tap(at: 0) == nil)
    #expect(tempo.tap(at: 1) == 60)
    #expect(tempo.tap(at: 1.125) == nil)
    #expect(tempo.tap(at: 1.625) == 120)
    #expect(tempo.tap(at: 5) == nil)
    #expect(tempo.tap(at: 5.5) == 120)
    #expect(tempo.tap(at: 6) == 120)
    #expect(tempo.tap(at: 7) == 90)
    #expect(tempo.tap(at: 8) == 80)
    #expect(tempo.tap(at: 9) == 69)
}
