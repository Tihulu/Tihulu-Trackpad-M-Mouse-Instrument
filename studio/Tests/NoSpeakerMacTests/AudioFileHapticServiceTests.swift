#if os(macOS)
import Foundation
import AVFoundation
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

/// Real local PCM container, no playback or private hardware access.
private func makeStereoFixture(_ url:URL,frameCount:Int) throws -> [Float] {
    let format = try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,
        sampleRate:16_000,channels:2,interleaved:false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frameCount)))
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let data = try #require(buffer.floatChannelData)
    var expected:[Float] = []
    expected.reserveCapacity(frameCount)
    for i in 0..<frameCount {
        let sample = Float(0.5*sin(2*Double.pi*440*Double(i)/16_000))
        data[0][i] = 0
        data[1][i] = sample
        expected.append(sample/2)
    }
    let file = try AVAudioFile(forWriting:url,settings:format.settings,
        commonFormat:.pcmFormatFloat32,interleaved:false)
    try file.write(from:buffer)
    return expected
}

@Test func nativeAudioFilePreservesSecondChannelAcrossDecodeChunkBoundary() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at:url) }
    let samples = try makeStereoFixture(url,frameCount:17_103)
    let expected = HapticSignalProcessor.hapticEvents(samples:samples,sampleRate:16_000,profile:.rhythm)
    let actual = try AudioFileHapticService.render(url:url,profile:.rhythm)
    #expect(!actual.isEmpty)
    #expect(actual == expected)
    #expect((actual.last?.time ?? 0) > 1.0)
}

@Test func nativeAudioFileHonorsCancelledRenderBeforeOpeningFile() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
    let cancellation = VoiceRenderCancellation()
    cancellation.cancel()
    #expect(throws:CancellationError.self) {
        try AudioFileHapticService.render(url:url,profile:.voice,cancellation:cancellation)
    }
    #expect(!FileManager.default.fileExists(atPath:url.path))
}
#endif
