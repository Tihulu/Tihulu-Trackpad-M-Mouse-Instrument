import Testing
@testable import NoSpeakerCore

private func drumTestFrame(_ hz: Double, level: Double = 0.7) -> HapticFrame {
    .init(tones:[.init(frequencyHz:hz),.init(frequencyHz:hz*2,amplitude:0.5)],durationMS:20,level:level)
}

@Test func simultaneousDrumFingersBothContributeToOneMotorFrame() throws {
    let kick = drumTestFrame(110), snare = drumTestFrame(350), hat = drumTestFrame(1200)
    let frame = try #require(DrumHapticMixer.mix([kick,snare,hat]))
    #expect(Set(frame.tones.map(\.frequencyHz)) == Set([110,220,350,700,1200,2400]))
    #expect(frame.tones.count == 6)
    #expect(frame.level == 0.7)
    #expect(DrumHapticMixer.mix([kick]) == kick)
}

@Test func holdingOneDrumFingerDoesNotBlockAnotherOrRetriggerHeldFinger() {
    var strikes = DrumHapticStrikeBuffer()
    let make: (String) -> HapticFrame? = { $0 == "A" ? drumTestFrame(110) : drumTestFrame(350) }
    strikes.receive(contacts:["A"],now:1,makeFrame:make)
    strikes.receive(contacts:["A","B"],now:1.004,makeFrame:make)
    strikes.receive(contacts:["A","B"],now:1.008,makeFrame:make)
    let first = strikes.drain(now:1.018)
    #expect(first == [drumTestFrame(110),drumTestFrame(350)])
    strikes.receive(contacts:["A"],now:1.019,makeFrame:make)
    strikes.receive(contacts:["A","B"],now:1.020,makeFrame:make)
    let retrigger = strikes.drain(now:1.036)
    #expect(retrigger == [drumTestFrame(350)])
    let empty = strikes.drain(now:1.037)
    #expect(empty.isEmpty)
}

@Test func drumStrikesExpireAndResetWithoutAStaleAttack() {
    var strikes = DrumHapticStrikeBuffer()
    strikes.receive(contacts:["A","B"],now:1) { _ in drumTestFrame(110) }
    let expired = strikes.drain(now:1.05)
    #expect(expired.isEmpty)
    strikes.receive(contacts:[],now:2) { _ in nil }
    strikes.receive(contacts:["A"],now:2.001) { _ in drumTestFrame(110) }
    strikes.reset()
    let retired = strikes.drain(now:2.002)
    #expect(retired.isEmpty)
}

@Test func drumMixerBoundsTonesAndUsesRoundRobinAcrossStrikes() throws {
    let hits = (0..<16).map { drumTestFrame(100+Double($0)*20) }
    let mixed = try #require(DrumHapticMixer.mix(hits))
    #expect(mixed.tones.count == 6)
    #expect(mixed.tones.map(\.frequencyHz) == [100,120,140,160,180,200])
    #expect(mixed.tones.allSatisfy { (0...1).contains($0.amplitude) })
    #expect(DrumHapticMixer.mix([drumTestFrame(.nan)]) == nil)
    #expect(DrumHapticMixer.mix([]) == nil)
}

@Test func rapidAlternatingDrumFingersPreserveEveryIsolatedStrike() {
    var strikes = DrumHapticStrikeBuffer()
    for i in 0..<1000 {
        let t = Double(i)*0.020
        strikes.receive(contacts:["kick","hat"],now:t) { id in drumTestFrame(id == "kick" ? 110 : 1200) }
        strikes.receive(contacts:[],now:t+0.002) { _ in nil }
        let hits = strikes.drain(now:t+0.018)
        #expect(hits.count == 2)
        #expect(DrumHapticMixer.mix(hits)?.tones.count == 4)
    }
}
