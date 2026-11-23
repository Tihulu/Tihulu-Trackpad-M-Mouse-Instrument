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

public enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "English"
    case turkish = "Turkish"
    case german = "German"

    public var id: String { rawValue }

    public var localePrefix: String {
        switch self {
        case .english: return "en"
        case .turkish: return "tr"
        case .german: return "de"
        }
    }
}

public enum VoiceHapticService {
    private static func installedVoiceRecords() -> [(name: String, locale: String)] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        return text.split(separator: "\n").compactMap { rawLine in
            let spokenPart = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? rawLine
            let fields = spokenPart.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { return nil }
            let locale = String(fields.last!)
            let name = fields.dropLast().joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return (name, locale)
        }
    }

    public static func installedVoices() -> [String] {
        Array(Set(installedVoiceRecords().map(\.name))).sorted()
    }

    public static func installedVoices(language: VoiceLanguage) -> [String] {
        let prefix = language.localePrefix.lowercased()
        return Array(Set(
            installedVoiceRecords()
                .filter { $0.locale.lowercased().hasPrefix(prefix) }
                .map(\.name)
        )).sorted()
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
