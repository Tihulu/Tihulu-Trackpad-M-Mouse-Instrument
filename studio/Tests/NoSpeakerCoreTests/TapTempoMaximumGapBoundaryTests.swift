import Testing
@testable import NoSpeakerCore

@Test(arguments: [0.0, 1.06, 1.15, 1.4, 1.9, 2.06, 2.39, 2.98, 100.0, 86_400.0, Double(1023.0).nextDown, Double(131071.0).nextDown])
func tapTempoAcceptsRoundedMaximumInterval(origin: Double) {
    var tempo = TapTempo()
    #expect(tempo.tap(at: origin) == nil)
    var time = origin
    for _ in 0..<6 {
        time += 3
        #expect(tempo.tap(at: time) == 20)
    }
}

@Test(arguments: [0.0, 1.06, 1.15, 1.4, 1.9, 2.06, 2.39, 2.98, 100.0, 86_400.0, Double(1023.0).nextDown, Double(131071.0).nextDown])
func tapTempoResetsAfterRepresentablyLongerInterval(origin: Double) {
    var tempo = TapTempo()
    #expect(tempo.tap(at: origin) == nil)
    let later = (origin + 3).nextUp
    #expect(tempo.tap(at: later) == nil)
    #expect(tempo.tap(at: later + 0.5) == 120)
}

@Test(arguments: [Double(1125899906842623.0).nextDown, Double(2251799813685247.0).nextDown,
                  Double(4503599627370495.0).nextDown, 1e16])
func tapTempoRetainsCoarseClockLongPauseReset(origin: Double) {
    var tempo = TapTempo()
    #expect(tempo.tap(at: origin) == nil)
    let later = origin + 3
    #expect(later - origin > 3)
    #expect(tempo.tap(at: later) == nil)
    #expect(tempo.tap(at: later + 2) == 30)
}
