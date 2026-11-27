import Foundation
import Testing
@testable import NoSpeakerCore

@Test(arguments: [1, 399, 400, 401, 559, 560, 561, 719, 720, 721], [Float.nan, .infinity, -.infinity])
func voiceRejectsInvalidPCMAtWindowBoundaries(length: Int, invalid: Float) throws {
    let valid = Array(repeating: Float(0.12), count: length)
    let expected = length < 400 ? 0 : (length - 400) / 160 + 1
    #expect(try HapticVoiceAnalyzer.analyze(valid, cancellation: .init()).count == expected)
    let end = expected == 0 ? 0 : 400 + (expected - 1) * 160
    let positions = Set([0, length - 1, end - 1, end, 399, 400, 559, 560]).filter { (0..<length).contains($0) }
    for position in positions.sorted() {
        var samples = valid
        samples[position] = invalid
        #expect(throws: VoiceAnalysisError.self) {
            try HapticVoiceAnalyzer.analyze(samples, cancellation: .init())
        }
        #expect(HapticVoiceAnalyzer.analyze(samples).isEmpty)
    }
}

@Test func invalidTailDoesNotOverridePrecancel() {
    for length in [1, 399, 401, 559, 561] {
        var samples = Array(repeating: Float(0.12), count: length)
        samples[length - 1] = .nan
        let token = VoiceRenderCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try HapticVoiceAnalyzer.analyze(samples, cancellation: token)
        }
    }
}
