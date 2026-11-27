import Foundation
import Testing
@testable import NoSpeakerCore

@Test func cancellableVoiceAnalysisMatchesExistingEntryPoint() throws {
    let input: [Float] = (0..<4800).map { i in
        let t = Double(i)/16000.0
        let fundamental = 0.15*sin(2.0*Double.pi*120.0*t)
        let harmonic = 0.08*sin(2.0*Double.pi*840.0*t)
        return Float(fundamental+harmonic)
    }
    let legacy = HapticVoiceAnalyzer.analyze(input)
    let current = try HapticVoiceAnalyzer.analyze(input,cancellation:.init())
    #expect(!legacy.isEmpty)
    #expect(current == legacy)
    #expect(HapticVoiceAnalyzer.hapticEvents(frames:current) == HapticVoiceAnalyzer.hapticEvents(frames:legacy))
}

@Test func voiceAnalysisPrecancelRejectsEvenEmptyInput() {
    let token = VoiceRenderCancellation()
    token.cancel()
    #expect(throws: CancellationError.self) {
        try HapticVoiceAnalyzer.analyze([],cancellation:token)
    }
    #expect(throws: CancellationError.self) {
        try HapticVoiceAnalyzer.analyze(Array(repeating:0.25,count:1600),cancellation:token)
    }
}

@Test(arguments: [1, 4, 9], [Float(0), 0.12])
func voiceAnalysisCanCancelDuringLongComputation(cancelAfter: Int, sample: Float) {
    let token = VoiceRenderCancellation()
    // Nine complete frames, including cancellation at the final boundary
    // before normalization. No wall-clock or global-queue scheduling race.
    let input = Array(repeating:sample,count:400+8*160)
    var processed: [Int] = []
    #expect(throws: CancellationError.self) {
        try HapticVoiceAnalyzer.analyze(input,cancellation:token,onFrameProcessed:{ count in
            processed.append(count)
            if count == cancelAfter { token.cancel() }
        })
    }
    #expect(processed == Array(1...cancelAfter))
}

@Test func voiceAnalysisFrameObserverPreservesUncancelledOutput() throws {
    let input: [Float] = (0..<1680).map { Float(0.12*sin(2*Double.pi*120*Double($0)/16000)) }
    var processed: [Int] = []
    let observed = try HapticVoiceAnalyzer.analyze(input,cancellation:.init(),onFrameProcessed:{ processed.append($0) })
    let ordinary = try HapticVoiceAnalyzer.analyze(input,cancellation:.init())
    #expect(processed == Array(1...9))
    #expect(observed == ordinary)
    #expect(HapticVoiceAnalyzer.hapticEvents(frames:observed) == HapticVoiceAnalyzer.hapticEvents(frames:ordinary))
}

@Test func voiceAnalysisRejectsInvalidPCMWithoutMotorEvents() {
    for value in [Float.nan,.infinity,-.infinity] {
        var samples = Array(repeating:Float(0.1),count:800)
        samples[420] = value
        #expect(throws: VoiceAnalysisError.self) {
            try HapticVoiceAnalyzer.analyze(samples,cancellation:.init())
        }
        #expect(HapticVoiceAnalyzer.analyze(samples).isEmpty)
    }
}
