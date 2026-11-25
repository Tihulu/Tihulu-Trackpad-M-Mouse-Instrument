import Foundation
import Testing
@testable import NoSpeakerCore

@Test func spectralAnalysisFindsATone() {
    let sampleRate = 8_000.0
    let samples = (0..<800).map { i in Float(sin(2 * Double.pi * 1_000 * Double(i) / sampleRate)) }
    let peaks = HapticSignalProcessor.dominantPeaks(
        samples: samples[...], sampleRate: sampleRate, minFrequency: 700, maxFrequency: 1_300, peakCount: 1, frequencyStep: 10
    )
    #expect(peaks.count == 1)
    #expect(abs(peaks[0].frequencyHz - 1_000) <= 20)
}

@Test func audioFramesStayInsideSafetyRange() {
    let sampleRate = 8_000.0
    let samples = (0..<1_600).map { i in Float(0.7 * sin(2 * Double.pi * 440 * Double(i) / sampleRate)) }
    let events = HapticSignalProcessor.hapticEvents(samples: samples, sampleRate: sampleRate, profile: .melody)
    #expect(!events.isEmpty)
    #expect(events.allSatisfy { event in
        event.frame.level >= 0 && event.frame.level <= 1 &&
        event.frame.tones.allSatisfy { $0.frequencyHz >= 98 && $0.frequencyHz <= 3_951 }
    })
}

@Test func parsesSimpleFormatZeroMIDI() throws {
    // Header: format 0, one track, 480 ticks/quarter.
    var bytes: [UInt8] = [
        0x4D,0x54,0x68,0x64, 0,0,0,6, 0,0, 0,1, 0x01,0xE0,
        0x4D,0x54,0x72,0x6B, 0,0,0,0
    ]
    let track: [UInt8] = [
        0x00, 0x90, 60, 100,                  // note on at tick 0
        0x83, 0x60, 0x80, 60, 0,             // note off at tick 480
        0x00, 0xFF, 0x2F, 0x00               // end track
    ]
    let length = track.count
    bytes[18] = UInt8((length >> 24) & 0xFF)
    bytes[19] = UInt8((length >> 16) & 0xFF)
    bytes[20] = UInt8((length >> 8) & 0xFF)
    bytes[21] = UInt8(length & 0xFF)
    bytes.append(contentsOf: track)

    let parsed = try MIDIFileParser.parse(Data(bytes))
    #expect(parsed.notes.count == 1)
    #expect(parsed.notes[0].note == 60)
    #expect(parsed.notes[0].channel == 0)
    #expect(abs(parsed.notes[0].durationSeconds - 0.5) < 0.0001)
}

@Test func voiceAnalyzerProducesSafeEvents() {
    let sr = HapticVoiceAnalyzer.sampleRate
    let samples = (0..<Int(sr * 0.2)).map { i in Float(0.5 * sin(2 * Double.pi * 120 * Double(i) / sr)) }
    let frames = HapticVoiceAnalyzer.analyze(samples)
    let events = HapticVoiceAnalyzer.hapticEvents(frames: frames)
    #expect(!frames.isEmpty)
    #expect(events.allSatisfy { event in event.frame.level <= 1 && event.frame.tones.count <= 6 })
}

@Test func midiTempoMetaEventChangesTiming() throws {
    var bytes: [UInt8] = [
        0x4D,0x54,0x68,0x64, 0,0,0,6, 0,0, 0,1, 0x01,0xE0,
        0x4D,0x54,0x72,0x6B, 0,0,0,0
    ]
    let track: [UInt8] = [
        0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, // 1,000,000 us/quarter = 60 BPM
        0x00, 0x90, 60, 100,
        0x83, 0x60, 0x80, 60, 0,
        0x00, 0xFF, 0x2F, 0x00
    ]
    let length = track.count
    bytes[18] = UInt8((length >> 24) & 0xFF)
    bytes[19] = UInt8((length >> 16) & 0xFF)
    bytes[20] = UInt8((length >> 8) & 0xFF)
    bytes[21] = UInt8(length & 0xFF)
    bytes.append(contentsOf: track)
    let parsed = try MIDIFileParser.parse(Data(bytes))
    #expect(parsed.notes.count == 1)
    #expect(abs(parsed.notes[0].durationSeconds - 1.0) < 0.0001)
}

@Test func midiChannelTenBecomesHapticDrum() {
    let midi = ParsedMIDIFile(notes: [
        MIDIFileNote(startSeconds: 0, durationSeconds: 0.2, channel: 9, note: 36, velocity: 127)
    ], durationSeconds: 0.2)
    let events = MIDIFileParser.hapticEvents(from: midi)
    #expect(events.count == 1)
    #expect(events[0].frame.tones.first?.frequencyHz == 120)
    #expect(events[0].frame.level == 1)
}


@Test func spectralAnalysisRejectsInvalidAndUnboundedArguments() {
    let input = Array(repeating:Float(0.2),count:128)
    #expect(HapticSignalProcessor.dominantPeaks(samples:input[...],sampleRate:8000,frequencyStep:0).isEmpty)
    #expect(HapticSignalProcessor.dominantPeaks(samples:input[...],sampleRate:8000,frequencyStep:.nan).isEmpty)
    #expect(HapticSignalProcessor.dominantPeaks(samples:input[...],sampleRate:8000,frequencyStep:1).isEmpty)
    #expect(HapticSignalProcessor.hapticEvents(samples:input,sampleRate:.infinity,profile:.voice).isEmpty)
    #expect(HapticSignalProcessor.hapticEvents(samples:input,sampleRate:8000,profile:.voice,frameDuration:.nan).isEmpty)
}

@Test func spectralAnalysisConstantOffsetIsSilent() {
    let input = Array(repeating:Float(0.4),count:1600)
    #expect(HapticSignalProcessor.dominantPeaks(samples:input[...],sampleRate:8000).isEmpty)
    for profile in AudioHapticProfile.allCases {
        #expect(HapticSignalProcessor.hapticEvents(samples:input,sampleRate:8000,profile:profile).isEmpty)
    }
}

@Test func spectralAnalysisGoertzelMatchesWindowedReference() throws {
    let rate = 8000.0,frequency = 720.0
    let samples = (0..<800).map { Float(0.1+0.5*sin(2*Double.pi*frequency*Double($0)/rate)) }
    let peak = try #require(HapticSignalProcessor.dominantPeaks(samples:samples[...],sampleRate:rate,
        minFrequency:frequency,maxFrequency:frequency,peakCount:1,frequencyStep:10).first)
    let mean = samples.reduce(0.0) { $0+Double($1) }/Double(samples.count)
    var re=0.0,im=0.0
    for (i,sample) in samples.enumerated() {
        let window=0.54-0.46*cos(2*Double.pi*Double(i)/Double(samples.count-1))
        let value=(Double(sample)-mean)*window
        let phase=2*Double.pi*frequency*Double(i)/rate
        re += value*cos(phase);im -= value*sin(phase)
    }
    #expect(abs(peak.magnitude-hypot(re,im)) < 0.00001)
}

@Test func offlineAudioAnalysisCancelsBeforeProducingEvents() {
    let cancellation = VoiceRenderCancellation()
    cancellation.cancel()
    #expect(throws:CancellationError.self) {
        try HapticSignalProcessor.hapticEvents(samples:Array(repeating:0.5,count:1600),
            sampleRate:8000,profile:.voice,cancellation:cancellation)
    }
}
