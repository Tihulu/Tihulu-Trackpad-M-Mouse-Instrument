import Testing
@testable import NoSpeakerCore

@Test(arguments: [0.0, 1.0, 10.0, 100.0, 1_000.0, 86_400.0, 1_000_000.0])
func tapTempoAcceptsRoundedMinimumInterval(origin: Double) {
    var tempo = TapTempo()
    #expect(tempo.tap(at: origin) == nil)
    var time = origin
    for _ in 0..<8 {
        time += 0.2
        #expect(tempo.tap(at: time) == 300)
    }
}

@Test(arguments: [0.0, 1.0, 10.0, 100.0, 1_000.0, 86_400.0, 1_000_000.0])
func tapTempoRejectsRepresentablyShorterInterval(origin: Double) {
    var tempo = TapTempo()
    #expect(tempo.tap(at: origin) == nil)
    let short = (origin + 0.2).nextDown
    #expect(tempo.tap(at: short) == nil)
    #expect(tempo.tap(at: short + 0.5) == 120)
}

@Test func tapTempoDoesNotExtendLongPauseAtCoarseTimestampPrecision() {
    var tempo = TapTempo()
    let origin = 1e16
    #expect(tempo.tap(at: origin) == nil)
    #expect(tempo.tap(at: origin + 4) == nil)
    #expect(tempo.tap(at: origin + 6) == 30)
}
