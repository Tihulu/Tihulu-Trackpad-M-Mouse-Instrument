#if os(macOS)
import Foundation
import AVFoundation
import NoSpeakerCore

public enum AudioFileHapticError: LocalizedError {
    case unsupportedChannels

    public var errorDescription: String? { "The audio file could not be converted to mono PCM." }
}

public enum AudioFileHapticService {
    public static func render(url: URL, profile: AudioHapticProfile) throws -> [ScheduledHapticEvent] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw AudioFileHapticError.unsupportedChannels }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw AudioFileHapticError.unsupportedChannels }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            for frame in 0..<frameCount { mono[frame] += channels[channelIndex][frame] / Float(max(1, channelCount)) }
        }
        return HapticSignalProcessor.hapticEvents(
            samples: mono,
            sampleRate: buffer.format.sampleRate,
            profile: profile
        )
    }
}
#endif
