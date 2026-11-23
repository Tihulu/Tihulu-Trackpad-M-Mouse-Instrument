#if os(macOS)
import Foundation
import AVFoundation
import NoSpeakerCore

public enum VoiceHapticError: LocalizedError {
    case voiceRenderFailed
    case audioReadFailed
    case speechTimedOut
    case piperNotInstalled
    case piperModelMissing

    public var errorDescription: String? {
        switch self {
        case .voiceRenderFailed: return "macOS could not render the selected voice."
        case .audioReadFailed: return "The rendered speech audio could not be read."
        case .speechTimedOut: return "Apple Speech could not finish rendering this voice. Try a different installed voice."
        case .piperNotInstalled: return "Local Piper speech engine not found. Install Piper from its official release or Python environment, then reopen the app."
        case .piperModelMissing: return "The selected Piper .onnx model or matching .onnx.json configuration is missing."
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

public enum VoiceBackend: String, Sendable {
    case say
    case avSpeech
    case piper
}

public struct VoiceOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var language: String
    public var backend: VoiceBackend

    public init(id: String, title: String, language: String, backend: VoiceBackend) {
        self.id = id
        self.title = title
        self.language = language
        self.backend = backend
    }
}

/// AVFoundation may expose higher-quality installed voices (including
/// enhanced/premium variants) that /usr/bin/say does not list. No voices
/// are invented or downloaded by this app.
private final class VoicePCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    let finished = DispatchSemaphore(value: 0)
    private var values: [Float] = []
    private var inputRate: Double = 16_000

    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
            finished.signal()
            return
        }
        let n = Int(pcm.frameLength)
        let rate = pcm.format.sampleRate
        var samples: [Float] = []
        if let channels = pcm.floatChannelData {
            samples = Array(UnsafeBufferPointer(start: channels[0], count: n))
        } else if let channels = pcm.int16ChannelData {
            samples = (0..<n).map { Float(channels[0][$0]) / 32_768 }
        } else if let channels = pcm.int32ChannelData {
            samples = (0..<n).map { Float(channels[0][$0]) / 2_147_483_648 }
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        inputRate = rate
        values.append(contentsOf: samples)
        lock.unlock()
    }

    func samples16kHz() -> [Float] {
        lock.lock()
        let input = values
        let rate = inputRate
        lock.unlock()
        guard rate > 0, rate.isFinite, !input.isEmpty else { return [] }
        if abs(rate - 16_000) < 1 { return input }
        let newCount = Int(Double(input.count) * 16_000 / rate)
        guard newCount > 0 else { return [] }
        let step = rate / 16_000
        return (0..<newCount).map { i in
            let pos = Double(i) * step
            let lo = min(input.count - 1, Int(pos))
            let hi = min(input.count - 1, lo + 1)
            let fract = Float(pos - Double(lo))
            return input[lo] * (1 - fract) + input[hi] * fract
        }
    }
}

public enum VoiceHapticService {
    /// Models are user-supplied and stay local. Do not download, redistribute,
    /// or presume commercial rights to any third-party voice automatically.
    public static func piperVoiceDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tihulu Trackpad & M. Mouse Instrument", isDirectory: true)
            .appendingPathComponent("Voices", isDirectory: true)
            .appendingPathComponent("tr_TR", isDirectory: true)
    }

    private static func localPiperExecutable() -> URL? {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let explicit = env["TIHULU_PIPER_BINARY"].map { URL(fileURLWithPath: $0) }
        let candidates = [explicit,
            URL(fileURLWithPath: "/opt/homebrew/bin/piper"),
            URL(fileURLWithPath: "/usr/local/bin/piper"),
            URL(fileURLWithPath: "/usr/local/opt/piper/bin/piper"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/piper")
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func piperIsInstalled() -> Bool { localPiperExecutable() != nil }

    private static func localPiperVoices(language: VoiceLanguage) -> [VoiceOption] {
        guard language == .turkish else { return [] }
        let directory = piperVoiceDirectory()
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "onnx" }
            .filter {
                fileManager.fileExists(atPath: $0.path + ".json")
            }
            .map { model in
                let name = model.deletingPathExtension().lastPathComponent
                let gender: String
                if name.localizedCaseInsensitiveContains("dfki") ||
                    name.localizedCaseInsensitiveContains("fahrettin") {
                    gender = " · Male"
                } else if name.localizedCaseInsensitiveContains("fettah") {
                    gender = " · Female"
                } else {
                    gender = ""
                }
                return VoiceOption(
                    id: "piper:" + model.lastPathComponent,
                    title: name + gender + " · Piper (local)",
                    language: "tr_TR", backend: .piper
                )
            }
    }

    private static func renderLocalPiper(text: String, filename: String) throws -> [ScheduledHapticEvent] {
        let modelURL = piperVoiceDirectory().appendingPathComponent(filename)
        // Never execute an arbitrary path as an audio model. Only local voice
        // files stored directly inside the dedicated application directory.
        guard filename == modelURL.lastPathComponent,
              filename.hasSuffix(".onnx"),
              FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: modelURL.path + ".json") else {
            throw VoiceHapticError.piperModelMissing
        }
        guard let executable = localPiperExecutable() else {
            throw VoiceHapticError.piperNotInstalled
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("tihulu-voice-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--model", modelURL.path, "--output_file", output.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((text + "\n").utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            throw VoiceHapticError.voiceRenderFailed
        }

        let audioFile = try AVAudioFile(forReading: output)
        guard audioFile.length > 0, audioFile.length < 22_050 * 240,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: audioFile.processingFormat,
                  frameCapacity: AVAudioFrameCount(audioFile.length)
              ) else { throw VoiceHapticError.audioReadFailed }
        try audioFile.read(into: buffer)
        let collector = VoicePCMCollector()
        collector.append(buffer)
        let samples = collector.samples16kHz()
        guard !samples.isEmpty else { throw VoiceHapticError.audioReadFailed }
        return HapticVoiceAnalyzer.hapticEvents(frames: HapticVoiceAnalyzer.analyze(samples))
    }

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

    public static func voiceOptions(language: VoiceLanguage) -> [VoiceOption] {
        let prefix = language.localePrefix.lowercased()
        let say = installedVoiceRecords().filter { $0.locale.lowercased().hasPrefix(prefix) }
        var options: [VoiceOption] = say.map {
            VoiceOption(id: "say:" + $0.name, title: $0.name + " · macOS say",
                        language: $0.locale, backend: .say)
        }
        let existingNames = Set(say.map { $0.name.lowercased() })
        let avOptions = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        for av in avOptions {
            let qualityLabel: String
            switch av.quality {
            case .premium: qualityLabel = " · Premium"
            case .enhanced: qualityLabel = " · Enhanced"
            default: qualityLabel = ""
            }
            // Keep the AVFoundation renderer visible for high-quality or
            // additional voices even if the name resembles a say voice.
            if !existingNames.contains(av.name.lowercased()) || av.quality != .default {
                options.append(VoiceOption(
                    id: "av:" + av.identifier,
                    title: av.name + qualityLabel + " · Apple Speech",
                    language: av.language,
                    backend: .avSpeech
                ))
            }
        }
        options.append(contentsOf: localPiperVoices(language: language))
        // Deduplicate by ID while preserving the distinct speech backends.
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func renderAVSpeech(text: String, identifier: String) throws -> [ScheduledHapticEvent] {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            throw VoiceHapticError.voiceRenderFailed
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let collector = VoicePCMCollector()
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.write(utterance) { buffer in collector.append(buffer) }
        guard collector.finished.wait(timeout: .now() + 90) == .success else {
            synthesizer.stopSpeaking(at: .immediate)
            throw VoiceHapticError.speechTimedOut
        }
        let samples = collector.samples16kHz()
        guard !samples.isEmpty else { throw VoiceHapticError.audioReadFailed }
        return HapticVoiceAnalyzer.hapticEvents(
            frames: HapticVoiceAnalyzer.analyze(samples)
        )
    }

    public static func render(text: String, voice: String? = nil) throws -> [ScheduledHapticEvent] {
        if let voice, voice.hasPrefix("piper:") {
            return try renderLocalPiper(text: text, filename: String(voice.dropFirst(6)))
        }
        if let voice, voice.hasPrefix("av:") {
            return try renderAVSpeech(text: text, identifier: String(voice.dropFirst(3)))
        }
        let sayVoice: String? = voice?.hasPrefix("say:") == true
            ? String(voice!.dropFirst(4)) : voice
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nospeaker-studio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000"]
            + (sayVoice.map { ["-v", $0] } ?? []) + [text]
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
