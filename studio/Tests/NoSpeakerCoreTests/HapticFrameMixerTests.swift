import Foundation
import Testing
@testable import NoSpeakerCore

private func frame(_ frequencies: [Double], level: Double = 0.5,
                   duration: Double = 40) -> HapticFrame {
    .init(tones: frequencies.map { .init(frequencyHz: $0) }, durationMS: duration, level: level)
}

@Test func mixerSoloPreservesShapeGainAndBoundsDuration() throws {
    var mixer = HapticFrameMixer()
    let lease = mixer.begin(.touch)
    let input = frame([220,440], level: 0.8)
    #expect(mixer.submit(input, from: lease, masterLevel: 0.5, now: 1))
    let output = try #require(mixer.render(now: 1))
    #expect(output.tones == input.tones)
    #expect(abs(output.level - 0.4) < 0.00001)
    #expect(output.durationMS == 18)
    let final = try #require(mixer.render(now: 1.035))
    #expect(abs(final.durationMS - 5) < 0.00001)
    #expect(mixer.render(now: 1.041) == nil)
}

@Test func mixerSharedNotesAndGainAreBounded() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.chords)
    #expect(mixer.submit(frame([220,440], level: 1), from: a, now: 1))
    #expect(mixer.submit(frame([440,660], level: 1), from: b, now: 1))
    let output = try #require(mixer.render(now: 1))
    #expect(Set(output.tones.map(\.frequencyHz)) == Set([220.0,440.0,660.0]))
    #expect(output.level == 1)
    #expect(abs(output.tones.reduce(0) { $0 + $1.amplitude } - 1) < 0.00001)
    #expect(output == HapticSafetyPolicy().clamp(output))
    #expect(mixer.release(a))
    let remaining = try #require(mixer.render(now: 1))
    #expect(remaining.tones.map(\.frequencyHz) == [440,660])
    #expect(mixer.release(b))
    #expect(mixer.render(now: 1) == nil)
}

@Test func mixerPolyphonySharesBudgetDeterministically() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch, priority: 10)
    let b = mixer.begin(.midi, priority: 0)
    #expect(mixer.submit(frame([200,300,400,500,600,700]), from: a, now: 1))
    #expect(mixer.submit(frame([800,900,1000,1100,1200,1300]), from: b, now: 1))
    let output = try #require(mixer.render(now: 1))
    #expect(output.tones.map(\.frequencyHz) == [200,800,300,900,400,1000])
    #expect(output.tones.count == 6)
    #expect(mixer.render(now: 1) == output)
}

@Test func mixerExclusiveFrameExpiresWithoutReplay() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.speech, mode: .exclusive)
    #expect(mixer.submit(frame([220], duration: 100), from: a, now: 1))
    #expect(mixer.submit(frame([900], duration: 10), from: b, now: 1))
    #expect(mixer.render(now: 1)?.tones.map(\.frequencyHz) == [900])
    #expect(mixer.render(now: 1.011)?.tones.map(\.frequencyHz) == [220])
    #expect(mixer.render(now: 1.101) == nil)
}

@Test func mixerRejectsOldLeasesInvalidFramesAndBackwardTime() {
    var mixer = HapticFrameMixer()
    let old = mixer.begin(.touch)
    let fresh = mixer.begin(.touch)
    #expect(!mixer.submit(frame([220]), from: old, now: 1))
    #expect(!mixer.release(old))
    #expect(mixer.submit(frame([440]), from: fresh, now: 1))
    #expect(!mixer.submit(frame([220]), from: fresh, now: 0.9))
    #expect(mixer.render(now: 0.9) == nil)
    #expect(!mixer.submit(frame([.nan]), from: fresh, now: 1))
    #expect(mixer.render(now: 1) == nil)
    #expect(!mixer.submit(frame([440]), from: fresh, masterLevel: .infinity, now: 1))
    #expect(mixer.submit(frame([440]), from: fresh, now: 1))
    #expect(mixer.submit(nil, from: fresh, now: 1))
    #expect(mixer.render(now: 1) == nil)
    mixer.releaseAll()
    #expect(mixer.sourceCount == 0)
    #expect(!mixer.submit(frame([440]), from: fresh, now: 1))
}

@Test func mixerReplacementDoesNotQueueFramesOrExtendExpiredVoices() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.midi)
    #expect(mixer.submit(frame([220], duration: 100), from: a, now: 1))
    #expect(mixer.submit(frame([330], duration: 100), from: a, now: 1))
    #expect(mixer.submit(frame([440], duration: 5), from: b, now: 1))
    let combined = try #require(mixer.render(now: 1))
    #expect(abs(combined.durationMS - 5) < 0.00001)
    #expect(Set(combined.tones.map(\.frequencyHz)) == Set([330.0,440.0]))
    #expect(mixer.render(now: 1.006)?.tones.map(\.frequencyHz) == [330])
    #expect(mixer.render(now: 1.101) == nil)
}
