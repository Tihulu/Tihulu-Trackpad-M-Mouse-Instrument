import Foundation
import Testing
@testable import NoSpeakerCore

@Test func cancellableVoiceAnalysisMatchesExistingEntryPoint() throws {
    let input: [Float] = (0..<4800).map { i in
        let t = Double(i)/16000
        return Float(0.15*sin(2*Double.pi*120*t)+0.08*sin(2*Double.pi*840*t))
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

@Test func voiceAnalysisCanCancelDuringLongComputation() {
    let token = VoiceRenderCancellation()
    let input = Array(repeating:Float(0.12),count:16000*30)
    DispatchQueue.global().asyncAfter(deadline:.now()+0.02) { token.cancel() }
    #expect(throws: CancellationError.self) {
        try HapticVoiceAnalyzer.analyze(input,cancellation:token)
    }
}
