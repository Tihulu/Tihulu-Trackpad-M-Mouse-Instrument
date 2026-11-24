import Foundation
import Testing
@testable import NoSpeakerCore

@Test func timelinePreservesSilentStepsAndFullBar() throws {
    let sequence = NoteSequence(bpm: 120, stepsPerBeat: 4, length: 16,
        steps: [.init(index: 0, midi: 60), .init(index: 4, midi: 64)])
    let duration = try #require(PlaybackTimeline.patternDuration(bpm: sequence.bpm,
                                      stepsPerBeat: sequence.stepsPerBeat, length: sequence.length))
    let timeline = PlaybackTimeline(events: try HapticPatternRenderer.notes(sequence), duration: duration, loop: true)
    #expect(timeline.duration == 2)
    #expect(timeline.events.map(\.time) == [0,0.5])
    #expect(timeline.canPlay)
}

@Test func timelineIncludesLastFrameForOneShot() {
    let input = ScheduledHapticEvent(time: 1, frame: .init(tones: [.init(frequencyHz: 440)],
                                                         durationMS: 80, level: 0.5))
    let timeline = PlaybackTimeline(events: [input])
    #expect(abs(timeline.duration - 1.08) < 0.00001)
    #expect(timeline.events == [input])
    #expect(PlaybackTimeline(events: [input], duration: 1.02).duration == timeline.duration)
}

@Test func timelineEmptyAndInvalidNeverLoop() {
    let empty = PlaybackTimeline(events: [], duration: 2, loop: true)
    #expect(!empty.canPlay)
    let bad = ScheduledHapticEvent(time: .nan, frame: .init(tones: [.init(frequencyHz: 440)], durationMS: 20, level: 1))
    #expect(!PlaybackTimeline(events: [bad]).canPlay)
    #expect(PlaybackTimeline.patternDuration(bpm: 0, stepsPerBeat: 4, length: 16) == nil)
    #expect(PlaybackTimeline.patternDuration(bpm: .infinity, stepsPerBeat: 4, length: 16) == nil)
    #expect(PlaybackTimeline.patternDuration(bpm: 120, stepsPerBeat: 0, length: 16) == nil)
}

@Test func timelineKeepsSimultaneousDrumOrderAndLoopBoundary() {
    let events = HapticPatternRenderer.drums(.init(bpm: 240, length: 16,
        hits: [.init(index: 15, voice: .kick), .init(index: 15, voice: .snare)]))
    let timeline = PlaybackTimeline(events: events, duration: 1, loop: true)
    #expect(timeline.duration == 1)
    #expect(timeline.events == events.map { .init(time: $0.time, frame: HapticSafetyPolicy().clamp($0.frame)) })
}

@Test func timelineSingleFirstBeatDoesNotCollapseLoop() {
    let events = HapticPatternRenderer.drums(.init(bpm: 120, length: 16,
                                                  hits: [.init(index: 0, voice: .kick)]))
    let timeline = PlaybackTimeline(events: events, duration: 2, loop: true)
    #expect(timeline.duration == 2)
    #expect(timeline.events.count == 1)
}
