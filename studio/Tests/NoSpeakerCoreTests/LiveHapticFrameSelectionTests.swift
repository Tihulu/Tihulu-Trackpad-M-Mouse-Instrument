import Testing
@testable import NoSpeakerCore

private func liveFrame(_ pitches:[Double], duration:Double = 18, level:Double = 0.5) -> HapticFrame {
    .init(tones:pitches.map { .init(frequencyHz:$0) },durationMS:duration,level:level)
}

@Test func liveAttackDoesNotReplaceCurrentHeldPitch() throws {
    let held = liveFrame([440,660],level:0.4)
    let attack = liveFrame([220,440],duration:12,level:0.6)
    let merged = try #require(LiveHapticFrameSelection.select(held:held,attack:attack))
    #expect(merged.tones.map(\.frequencyHz) == [440,660,220])
    #expect(merged.durationMS == 12 && merged.level == 0.6)
    #expect(LiveHapticFrameSelection.select(held:held,attack:nil) == held)
    #expect(LiveHapticFrameSelection.select(held:nil,attack:attack) == attack)
    #expect(LiveHapticFrameSelection.select(held:nil,attack:nil) == nil)
}

@Test func heldPolyphonyRetainsAllCurrentTonesAndRejectsExcessAttack() throws {
    let held = liveFrame([220,330,440,550,660,770])
    #expect(LiveHapticFrameSelection.select(held:held,attack:liveFrame([880])) == held)
    let five = liveFrame([220,330,440,550,660])
    let mixed = try #require(LiveHapticFrameSelection.select(held:five,attack:liveFrame([550,880,990])))
    #expect(mixed.tones.map(\.frequencyHz) == [220,330,440,550,660,880])
    #expect(mixed == HapticSafetyPolicy().clamp(mixed))
}

@Test func duplicateOrInvalidBufferedAttackDoesNotDisturbHeldFrame() {
    let held = liveFrame([220,440])
    #expect(LiveHapticFrameSelection.select(held:held,attack:liveFrame([440,220],level:1)) == held)
    #expect(LiveHapticFrameSelection.select(held:held,attack:liveFrame([.nan])) == held)
    #expect(LiveHapticFrameSelection.select(held:held,attack:liveFrame([880],duration:121)) == held)
    #expect(LiveHapticFrameSelection.select(held:held,attack:liveFrame([880],level:0)) == held)
}
