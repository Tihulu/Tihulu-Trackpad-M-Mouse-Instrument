#if os(macOS)
import Foundation
import AVFoundation
import NoSpeakerCore

public enum VoiceHapticError: LocalizedError {
    case voiceRenderFailed
    case audioReadFailed

    public var errorDescription: String? {
        switch self {
        case .voiceRenderFailed: return "macOS could not render the selected voice."
        case .audioReadFailed: return "The rendered speech audio could not be read."
        }
    }
}

public enum VoiceHapticService {
    public static func installedVoices() -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return fields.first.map(String.init)
        }
    }

    public static func render(text: String, voice: String? = nil) throws -> [ScheduledHapticEvent] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nospeaker-studio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000"]
            + (voice.map { ["-v", $0] } ?? []) + [text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoiceHapticError.voiceRenderFailed }

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw VoiceHapticError.audioReadFailed }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw VoiceHapticError.audioReadFailed }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let frames = HapticVoiceAnalyzer.analyze(samples)
        return HapticVoiceAnalyzer.hapticEvents(frames: frames)
    }
}
#endif
