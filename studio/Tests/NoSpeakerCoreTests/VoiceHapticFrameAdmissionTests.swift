import Testing
@testable import NoSpeakerCore

private func audibleVoicedFrame() -> HapticVoiceFrame {
    var frame = HapticVoiceFrame()
    frame.level = 0.5
    frame.voiced = true
    return frame
}

@Test(arguments: Array(0..<24))
func voiceHapticRejectsMalformedNumericFields(kind: Int) {
    var frame = audibleVoicedFrame()
    switch kind {
    case 0: frame.level = .infinity
    case 1: frame.level = .nan
    case 2: frame.level = -.infinity
    case 3: frame.level = -1
    case 4: frame.level = 0
    case 5: frame.formants[0] = .nan
    case 6: frame.formants[1] = .infinity
    case 7: frame.formants[0] = -.infinity
    case 8: frame.formants[1] = -1
    case 9: frame.formants[0] = 0
    case 10: frame.amplitudes[0] = .nan
    case 11: frame.amplitudes[1] = .infinity
    case 12: frame.amplitudes[0] = -.infinity
    case 13: frame.amplitudes[1] = -1
    case 14: frame.amplitudes[0] = -1
    case 15: frame.amplitudes[1] = .greatestFiniteMagnitude
    case 16: frame.amplitudes = [.greatestFiniteMagnitude, .greatestFiniteMagnitude / 2, 0]
    case 17: frame.fundamentalHz = .nan
    case 18: frame.fundamentalHz = .infinity
    case 19: frame.fundamentalHz = -.infinity
    case 20: frame.fundamentalHz = 0
    case 21: frame.fundamentalHz = -1
    case 22: frame.voiced = false; frame.level = .infinity
    default: frame.voiced = false; frame.level = .nan
    }
    let before = audibleVoicedFrame()
    let result = HapticVoiceAnalyzer.hapticEvents(frames: [before, frame, before])
    #expect(result == HapticVoiceAnalyzer.hapticEvents(frames: [before, HapticVoiceFrame(), before]))
    #expect(result.map(\.time) == [0, 2 * HapticVoiceAnalyzer.hopSeconds])
}

@Test(arguments: Array(0...3), Array(0...3))
func voiceHapticChecksConsumedLaneShape(formants: Int, amplitudes: Int) {
    var frame = audibleVoicedFrame()
    frame.formants = Array(repeating: 500, count: formants)
    frame.amplitudes = Array(repeating: 0.25, count: amplitudes)
    let voiced = HapticVoiceAnalyzer.hapticEvents(frames: [frame])
    #expect(voiced.count == (formants >= 2 && amplitudes >= 2 ? 1 : 0))
    if let event = voiced.first { #expect(event.frame.tones.count == 2) }
    frame.voiced = false
    frame.fundamentalHz = .nan
    let unvoiced = HapticVoiceAnalyzer.hapticEvents(frames: [frame])
    #expect(unvoiced.count == 1)
    #expect(unvoiced.first?.frame.tones == [HapticTone(frequencyHz: 2750, amplitude: 1)])
}

@Test func voiceHapticPreservesFiniteClampingAndUnusedLanes() throws {
    var frame = audibleVoicedFrame()
    frame.formants = [50, 5000, .nan]
    frame.amplitudes = [0, 0, .nan]
    frame.fundamentalHz = 50
    frame.level = 2
    let event = try #require(HapticVoiceAnalyzer.hapticEvents(frames: [frame]).first)
    #expect(event.frame.level == 1)
    #expect(event.frame.durationMS == 10)
    #expect(event.frame.tones == [HapticTone(frequencyHz: 98, amplitude: 0), HapticTone(frequencyHz: 3951, amplitude: 0)])
}
