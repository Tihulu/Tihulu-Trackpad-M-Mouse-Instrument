import Testing
@testable import NoSpeakerCore

private let drum = HapticFrame(tones:[.init(frequencyHz:110),.init(frequencyHz:220)],durationMS:70,level:0.8)
private let melody = HapticFrame(tones:[.init(frequencyHz:440)],durationMS:28,level:0.6)

@Test func mixedTouchRenderPreservesStandaloneWaveforms() {
    var plan = TouchHapticRenderPlan()
    let hit = plan.next(hits:[drum],melody:nil,now:1)
    #expect(hit == drum)
    let idle = plan.next(hits:[],melody:nil,now:1.018)
    #expect(idle == nil)
    let voice = plan.next(hits:[],melody:melody,now:1.09)
    #expect(voice == melody)
}

@Test func mixedTouchRenderDoesNotStarveMelodyDuringRepeatedDrums() {
    var plan = TouchHapticRenderPlan()
    for i in 0..<1000 {
        let now = 1+Double(i)*0.018
        let frame = plan.next(hits:i%2 == 0 ? [drum] : [],melody:melody,now:now)
        #expect(frame?.tones.contains(where:{ $0.frequencyHz == 110 }) == true)
        #expect(frame?.tones.contains(where:{ $0.frequencyHz == 440 }) == true)
        #expect(frame?.durationMS == 18)
        #expect(frame?.level == 0.8)
    }
}

@Test func mixedTouchRenderDoesNotExtendOriginalDrumDeadline() throws {
    var plan = TouchHapticRenderPlan()
    _ = plan.next(hits:[drum],melody:melody,now:1)
    _ = plan.next(hits:[],melody:melody,now:1.018)
    _ = plan.next(hits:[],melody:melody,now:1.036)
    let last = plan.next(hits:[],melody:melody,now:1.054)
    #expect(abs((last?.durationMS ?? 0)-16) < 0.00001)
    let expired = plan.next(hits:[],melody:melody,now:1.072)
    #expect(expired == melody)
    let idle = plan.next(hits:[],melody:nil,now:1.09)
    #expect(idle == nil)
}

@Test func mixedTouchRenderResumesTailOnlyOnceAfterMelodyRelease() {
    var plan = TouchHapticRenderPlan()
    _ = plan.next(hits:[drum],melody:melody,now:1)
    let tail = plan.next(hits:[],melody:nil,now:1.018)
    #expect(abs((tail?.durationMS ?? 0)-52) < 0.00001)
    #expect(tail?.tones == drum.tones)
    let idle = plan.next(hits:[],melody:nil,now:1.036)
    #expect(idle == nil)
    plan.reset()
    let stopped = plan.next(hits:[],melody:nil,now:1.04)
    #expect(stopped == nil)
}

@Test func mixedTouchRenderRejectsInvalidClockAndRetiresTail() {
    var plan = TouchHapticRenderPlan()
    _ = plan.next(hits:[drum],melody:melody,now:1)
    let invalid = plan.next(hits:[drum],melody:melody,now:.nan)
    #expect(invalid == nil)
    let after = plan.next(hits:[],melody:melody,now:1.018)
    #expect(after == melody)
    let reversed = plan.next(hits:[drum],melody:nil,now:0.5)
    #expect(reversed == nil)
}

@Test func percussionInvalidationClearsPendingWithoutRearmingHeldContact() {
    var buffer = DrumHapticStrikeBuffer()
    buffer.receive(contacts:["a"],now:1) { _ in drum }
    buffer.discardPending()
    buffer.receive(contacts:["a"],now:1.001) { _ in drum }
    let held = buffer.drain(now:1.002)
    #expect(held.isEmpty)
    buffer.receive(contacts:[],now:1.003) { _ in nil }
    buffer.receive(contacts:["a"],now:1.004) { _ in drum }
    let retrigger = buffer.drain(now:1.005)
    #expect(retrigger == [drum])
}
