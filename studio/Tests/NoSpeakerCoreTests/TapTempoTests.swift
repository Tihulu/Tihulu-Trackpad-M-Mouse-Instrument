import Testing
@testable import NoSpeakerCore

@Test func tapTempoAveragesRecentTapsAndResetsAfterPause() {
    var tempo = TapTempo()
    #expect(tempo.tap(at: 10) == nil)
    #expect(tempo.tap(at: 10.5) == 120)
    #expect(tempo.tap(at: 11) == 120)
    #expect(tempo.tap(at: 20) == nil)
    #expect(tempo.tap(at: 21) == 60)
    #expect(tempo.tap(at: 20) == nil)
    #expect(tempo.tap(at: .nan) == nil)
}

@Test func tempoRejectsInvalidOrExtremeValues() {
    #expect(TapTempo.safeBPM(.nan) == 120)
    #expect(TapTempo.safeBPM(0) == 20)
    #expect(TapTempo.safeBPM(500) == 300)
}
