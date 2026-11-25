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
    let check1 = mixer.submit(input, from: lease, masterLevel: 0.5, now: 1)
    #expect(check1)
    let candidate2 = mixer.render(now: 1)
    let output = try #require(candidate2)
    #expect(output.tones == input.tones)
    #expect(abs(output.level - 0.4) < 0.00001)
    #expect(output.durationMS == 18)
    let candidate3 = mixer.render(now: 1.035)
    let final = try #require(candidate3)
    #expect(abs(final.durationMS - 5) < 0.00001)
    let check4 = mixer.render(now: 1.041) == nil
    #expect(check4)
}

@Test func mixerSharedNotesAndGainAreBounded() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.chords)
    let check5 = mixer.submit(frame([220,440], level: 1), from: a, now: 1)
    #expect(check5)
    let check6 = mixer.submit(frame([440,660], level: 1), from: b, now: 1)
    #expect(check6)
    let candidate7 = mixer.render(now: 1)
    let output = try #require(candidate7)
    #expect(Set(output.tones.map(\.frequencyHz)) == Set([220.0,440.0,660.0]))
    #expect(output.level == 1)
    #expect(abs(output.tones.reduce(0) { $0 + $1.amplitude } - 1) < 0.00001)
    #expect(output == HapticSafetyPolicy().clamp(output))
    let check8 = mixer.release(a)
    #expect(check8)
    let candidate9 = mixer.render(now: 1)
    let remaining = try #require(candidate9)
    #expect(remaining.tones.map(\.frequencyHz) == [440,660])
    let check10 = mixer.release(b)
    #expect(check10)
    let check11 = mixer.render(now: 1) == nil
    #expect(check11)
}

@Test func mixerPolyphonySharesBudgetDeterministically() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch, priority: 10)
    let b = mixer.begin(.midi, priority: 0)
    let check12 = mixer.submit(frame([200,300,400,500,600,700]), from: a, now: 1)
    #expect(check12)
    let check13 = mixer.submit(frame([800,900,1000,1100,1200,1300]), from: b, now: 1)
    #expect(check13)
    let candidate14 = mixer.render(now: 1)
    let output = try #require(candidate14)
    #expect(output.tones.map(\.frequencyHz) == [200,800,300,900,400,1000])
    #expect(output.tones.count == 6)
    let check15 = mixer.render(now: 1) == output
    #expect(check15)
}

@Test func mixerExclusiveFrameExpiresWithoutReplay() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.speech, mode: .exclusive)
    let check16 = mixer.submit(frame([220], duration: 100), from: a, now: 1)
    #expect(check16)
    let check17 = mixer.submit(frame([900], duration: 10), from: b, now: 1)
    #expect(check17)
    let check18 = mixer.render(now: 1)?.tones.map(\.frequencyHz) == [900]
    #expect(check18)
    let check19 = mixer.render(now: 1.011)?.tones.map(\.frequencyHz) == [220]
    #expect(check19)
    let check20 = mixer.render(now: 1.101) == nil
    #expect(check20)
}

@Test func mixerRejectsOldLeasesInvalidFramesAndBackwardTime() {
    var mixer = HapticFrameMixer()
    let old = mixer.begin(.touch)
    let fresh = mixer.begin(.touch)
    let check21 = !mixer.submit(frame([220]), from: old, now: 1)
    #expect(check21)
    let check22 = !mixer.release(old)
    #expect(check22)
    let check23 = mixer.submit(frame([440]), from: fresh, now: 1)
    #expect(check23)
    let check24 = !mixer.submit(frame([220]), from: fresh, now: 0.9)
    #expect(check24)
    let check25 = mixer.render(now: 0.9) == nil
    #expect(check25)
    let check26 = !mixer.submit(frame([.nan]), from: fresh, now: 1)
    #expect(check26)
    let check27 = mixer.render(now: 1) == nil
    #expect(check27)
    let check28 = !mixer.submit(frame([440]), from: fresh, masterLevel: .infinity, now: 1)
    #expect(check28)
    let check29 = mixer.submit(frame([440]), from: fresh, now: 1)
    #expect(check29)
    let check30 = mixer.submit(nil, from: fresh, now: 1)
    #expect(check30)
    let check31 = mixer.render(now: 1) == nil
    #expect(check31)
    mixer.releaseAll()
    #expect(mixer.sourceCount == 0)
    let check32 = !mixer.submit(frame([440]), from: fresh, now: 1)
    #expect(check32)
}

@Test func mixerReplacementDoesNotQueueFramesOrExtendExpiredVoices() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.touch)
    let b = mixer.begin(.midi)
    let check33 = mixer.submit(frame([220], duration: 100), from: a, now: 1)
    #expect(check33)
    let check34 = mixer.submit(frame([330], duration: 100), from: a, now: 1)
    #expect(check34)
    let check35 = mixer.submit(frame([440], duration: 5), from: b, now: 1)
    #expect(check35)
    let candidate36 = mixer.render(now: 1)
    let combined = try #require(candidate36)
    #expect(abs(combined.durationMS - 5) < 0.00001)
    #expect(Set(combined.tones.map(\.frequencyHz)) == Set([330.0,440.0]))
    let check37 = mixer.render(now: 1.006)?.tones.map(\.frequencyHz) == [330]
    #expect(check37)
    let check38 = mixer.render(now: 1.101) == nil
    #expect(check38)
}

@Test func mixerThreeLiveSourcesShareSixVoicesAndRetireIndependently() throws {
    var mixer = HapticFrameMixer()
    let a = mixer.begin(.chords)
    let b = mixer.begin(.touchBar)
    let g = mixer.begin(.gamepad)
    let fa = frame([220,230,240,250,260,270])
    let fb = frame([440,450,460,470,480,490])
    let fg = frame([660,670,680,690,700,710])
    let check39 = mixer.submit(fa,from:a,now:1)
    #expect(check39)
    let check40 = mixer.submit(fb,from:b,now:1)
    #expect(check40)
    let check41 = mixer.submit(fg,from:g,now:1)
    #expect(check41)
    let allCandidate = mixer.render(now:1)
    let all = try #require(allCandidate)
    #expect(all.tones.map(\.frequencyHz) == [220,660,440,230,670,450])
    #expect(all.level <= 1 && all.durationMS <= 18)
    let check42 = mixer.release(g)
    #expect(check42)
    let check43 = !mixer.submit(fg,from:g,now:1)
    #expect(check43)
    let twoCandidate = mixer.render(now:1)
    let two = try #require(twoCandidate)
    #expect(two.tones.map(\.frequencyHz) == [220,440,230,450,240,460])
    let fresh = mixer.begin(.gamepad)
    let check44 = !mixer.release(g)
    #expect(check44)
    let check45 = mixer.submit(fg,from:fresh,now:1)
    #expect(check45)
    let check46 = mixer.release(a)
    #expect(check46)
    let check47 = mixer.release(b)
    #expect(check47)
    let check48 = mixer.render(now:1)?.tones == fg.tones
    #expect(check48)
    let check49 = mixer.render(now:1.05) == nil
    #expect(check49)
    mixer.releaseAll()
    #expect(mixer.sourceCount == 0)
    let check50 = !mixer.submit(fg,from:fresh,now:1.06)
    #expect(check50)
}
