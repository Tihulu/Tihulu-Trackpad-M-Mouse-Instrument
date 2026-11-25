import Foundation
import Testing
@testable import NoSpeakerCore

private func clip(_ hz: Double, count: Int = 3_200) -> [Float] {
    (0..<count).map { i in
        Float(0.15 * sin(2 * .pi * hz * Double(i) / 16_000))
    }
}

@Test func liveAnalysisIsIndependentOfPacketBoundaries() {
    let input = clip(220)
    var whole = LiveSpeechProcessor(sampleRate: 16_000)
    var split = LiveSpeechProcessor(sampleRate: 16_000)
    let expected = whole.append(input)
    var actual: [HapticFrame?] = []
    for i in Swift.stride(from: 0, to: input.count, by: 137) {
        actual += split.append(Array(input[i..<min(input.count, i + 137)]))
    }
    #expect(actual == expected)
    #expect(actual.count == 18)
    #expect(actual.compactMap { $0 }.count > 10)
}

@Test func liveAnalysisPreservesSilenceAndMotorBounds() {
    var processor = LiveSpeechProcessor(sampleRate: 16_000)
    let silence = processor.append(Array(repeating: 0, count: 1_600))
    #expect(silence.count == 8)
    #expect(silence.allSatisfy { $0 == nil })
    let frames = processor.append(clip(290)).compactMap { $0 }
    #expect(!frames.isEmpty)
    for frame in frames {
        #expect(HapticSafetyPolicy().clamp(frame) == frame)
        #expect(frame.tones.allSatisfy { $0.frequencyHz.isFinite && $0.amplitude.isFinite })
    }
}

@Test func playoutDoesNotBurstOverdueFramesAndPreservesGaps() {
    let frame = HapticFrame(tones: [.init(frequencyHz: 500)], durationMS: 8, level: 0.5)
    var timeline = LiveHapticTimeline(bufferSeconds: 0.10)
    timeline.enqueue([frame, nil, frame], now: 1.0)
    #expect(timeline.takeDue(now: 1.05) == nil)
    #expect(timeline.takeDue(now: 1.101) == frame)
    #expect(timeline.takeDue(now: 1.111) == nil)
    #expect(timeline.takeDue(now: 1.121) == frame)
    timeline.enqueue(Array(repeating: frame, count: 20), now: 2)
    #expect(timeline.takeDue(now: 3) == nil)
    #expect(timeline.pending == 0)
    #expect(timeline.dropped >= 20)
}

@Test func playoutBufferIsBounded() {
    var timeline = LiveHapticTimeline()
    timeline.enqueue(Array(repeating: nil, count: 100), now: 0)
    #expect(timeline.pending <= 60)
    #expect(timeline.dropped == 40)
}


@Test func liveSpeechRejectsConstantDCAsSilenceInEveryProfile() {
    for profile in AudioHapticProfile.allCases {
        var processor = LiveSpeechProcessor(sampleRate:16_000,profile:profile)
        let result = processor.append(Array(repeating:0.3,count:3200))
        #expect(result.count == 18)
        #expect(result.allSatisfy { $0 == nil })
    }
}

@Test func liveSpeechDCOffsetPreservesToneAndGain() {
    let input = clip(220)
    var baseline = LiveSpeechProcessor(sampleRate:16_000)
    var offset = LiveSpeechProcessor(sampleRate:16_000)
    let a = baseline.append(input).compactMap { $0 }
    let b = offset.append(input.map { $0+0.4 }).compactMap { $0 }
    #expect(a.count == b.count && !a.isEmpty)
    for (left,right) in zip(a,b) {
        #expect(abs(left.level-right.level) < 0.00001)
        #expect(left.tones.map(\.frequencyHz) == right.tones.map(\.frequencyHz))
    }
}

@Test func speakerTimelineInvalidOrReversedClockDiscardsQueuedAudio() {
    let frame = HapticFrame(tones:[.init(frequencyHz:440)],durationMS:8,level:0.5)
    var timeline = LiveHapticTimeline(bufferSeconds:0.1)
    timeline.enqueue([frame,frame],now:2)
    let reversed = timeline.takeDue(now:1.9)
    #expect(reversed == nil && timeline.pending == 0 && timeline.dropped == 2)
    timeline.enqueue([frame],now:1.95)
    #expect(timeline.pending == 0)
    timeline.enqueue([frame],now:2.2)
    let invalid = timeline.takeDue(now:.nan)
    #expect(invalid == nil && timeline.pending == 0 && timeline.dropped == 3)
    timeline.enqueue([frame],now:2.3)
    let recovered = timeline.takeDue(now:2.401)
    #expect(recovered == frame)
}
