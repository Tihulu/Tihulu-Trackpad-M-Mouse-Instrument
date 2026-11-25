#if os(macOS)
import Foundation
import AVFoundation
import NoSpeakerCore

public enum AudioFileHapticError: LocalizedError {
    case unsupportedChannels
    case fileTooLarge
    case invalidSample

    public var errorDescription: String? {
        switch self {
        case .unsupportedChannels: return "The audio file could not be converted to supported mono PCM."
        case .fileTooLarge: return "Audio exceeds the offline analysis limit (48 million decoded frames or 30 minutes). Split the file and retry."
        case .invalidSample: return "Audio contains a nonfinite PCM sample."
        }
    }
}

public enum AudioFileHapticService {
    public static func render(url: URL, profile: AudioHapticProfile) throws -> [ScheduledHapticEvent] {
        try render(url:url,profile:profile,cancellation:VoiceRenderCancellation())
    }

    public static func render(url:URL,profile:AudioHapticProfile,
                              cancellation:VoiceRenderCancellation) throws -> [ScheduledHapticEvent] {
        try cancellation.check()
        let file = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let format = file.processingFormat
        let rate = format.sampleRate,channels = Int(format.channelCount)
        guard rate.isFinite,(8_000...192_000).contains(rate),(1...8).contains(channels),
              file.length > 0 else { throw AudioFileHapticError.unsupportedChannels }
        let limit = min(48_000_000,Int(rate*1800))
        guard file.length <= AVAudioFramePosition(limit) else { throw AudioFileHapticError.fileTooLarge }
        let chunk = AVAudioFrameCount(16_384)
        guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:chunk) else {
            throw AudioFileHapticError.unsupportedChannels
        }
        var mono:[Float] = []
        let declaredFrames = Int(file.length)
        mono.reserveCapacity(declaredFrames)
        // Avoid a read after EOF (some native decoders return an error
        // instead of an empty buffer). Do not request beyond known frames.
        while mono.count < declaredFrames {
            try cancellation.check()
            let requested = min(Int(chunk),declaredFrames-mono.count)
            buffer.frameLength = 0
            try file.read(into:buffer,frameCount:AVAudioFrameCount(requested))
            let frames = Int(buffer.frameLength)
            guard frames > 0,frames <= requested else { throw AudioFileHapticError.unsupportedChannels }
            guard frames <= limit-mono.count else { throw AudioFileHapticError.fileTooLarge }
            guard let data = buffer.floatChannelData else { throw AudioFileHapticError.unsupportedChannels }
            for i in 0..<frames {
                var value:Double = 0
                for channel in 0..<channels {
                    let sample = data[channel][i]
                    guard sample.isFinite else { throw AudioFileHapticError.invalidSample }
                    value += Double(max(-1,min(1,sample)))/Double(channels)
                }
                mono.append(Float(value))
            }
        }
        guard !mono.isEmpty else { throw AudioFileHapticError.unsupportedChannels }
        try cancellation.check()
        return try HapticSignalProcessor.hapticEvents(samples:mono,sampleRate:rate,profile:profile,cancellation:cancellation)
    }
}
#endif
