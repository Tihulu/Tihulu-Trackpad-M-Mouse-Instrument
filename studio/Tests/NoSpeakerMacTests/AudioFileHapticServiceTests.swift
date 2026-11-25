#if os(macOS)
import Foundation
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

/// Hand-built PCM16 WAV: no AVFoundation writer dependency or codec
/// assumptions in the fixture. Only the right channel contains a tone.
private func makeStereoFixture(_ url:URL,frameCount:Int) throws -> [Float] {
    var bytes = Data()
    func tag(_ value:String) { bytes.append(contentsOf:value.utf8) }
    func u16(_ value:UInt16) {
        bytes.append(UInt8(truncatingIfNeeded:value))
        bytes.append(UInt8(truncatingIfNeeded:value>>8))
    }
    func u32(_ value:UInt32) {
        u16(UInt16(truncatingIfNeeded:value))
        u16(UInt16(truncatingIfNeeded:value>>16))
    }
    let payload = UInt32(frameCount*4)
    tag("RIFF");u32(36+payload);tag("WAVE")
    tag("fmt ");u32(16);u16(1);u16(2);u32(16_000);u32(64_000);u16(4);u16(16)
    tag("data");u32(payload)
    var expected:[Float] = []
    for i in 0..<frameCount {
        let sample = Int16((16_000*sin(2*Double.pi*440*Double(i)/16_000)).rounded())
        u16(0);u16(UInt16(bitPattern:sample))
        expected.append(Float(sample)/65_536)
    }
    try bytes.write(to:url,options:.atomic)
    return expected
}

@Test func nativeAudioFilePreservesSecondChannelAcrossDecodeChunkBoundary() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at:url) }
    let samples = try makeStereoFixture(url,frameCount:17_103)
    let expected = HapticSignalProcessor.hapticEvents(samples:samples,sampleRate:16_000,profile:.rhythm)
    let actual:[ScheduledHapticEvent]
    do { actual = try AudioFileHapticService.render(url:url,profile:.rhythm) }
    catch { Issue.record("Production WAV decode failed: \(String(describing:error))");throw error }
    #expect(!actual.isEmpty)
    #expect(actual == expected)
    #expect((actual.last?.time ?? 0) > 1.0)
}

@Test func nativeAudioFileHonorsCancelledRenderBeforeOpeningFile() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    let cancellation = VoiceRenderCancellation()
    cancellation.cancel()
    #expect(throws:CancellationError.self) {
        try AudioFileHapticService.render(url:url,profile:.voice,cancellation:cancellation)
    }
    #expect(!FileManager.default.fileExists(atPath:url.path))
}
#endif
