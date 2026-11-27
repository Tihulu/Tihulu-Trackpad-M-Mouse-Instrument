import Foundation

/// Versioned offline profile. Retains the exact source pair so no cents,
/// holes, or reference calibration are lost in a serialization round trip.
/// Never contains activation consent, device IDs, routes or unlock flags.
public struct ScalaKeyboardProfile: Equatable, Sendable {
    public enum Failure: Error, Equatable, Sendable { case invalidEnvelope, unsupportedVersion }
    public static let maximumBytes = 262_144
    public let scaleText: String
    public let mappingText: String
    public let preview: ScalaKeyboardPreview

    private struct Envelope: Codable {
        let version: Int
        let scale: String
        let mapping: String
    }

    /// Stable, data-free diagnostics for a draft import screen. The caller
    /// decides how to present these codes; no source text or path is logged.
    public enum SourceStage: String, Equatable, Sendable { case scale, mapping, calibration }
    public enum ValidationIssue: Error, Equatable, Sendable {
        case invalidEnvelope, unsupportedVersion
        case source(stage: SourceStage, reason: ScalaKeyboardImport.Failure)

        fileprivate var legacyError: any Error {
            switch self {
            case .invalidEnvelope: return Failure.invalidEnvelope
            case .unsupportedVersion: return Failure.unsupportedVersion
            case .source(_, let reason): return reason
            }
        }
    }

    private init(scaleText: String, mappingText: String, preview: ScalaKeyboardPreview) {
        self.scaleText = scaleText
        self.mappingText = mappingText
        self.preview = preview
    }

    /// Reuses the existing strict parsers and calibration; a successful
    /// result is the validated immutable profile, not a second draft parse.
    public static func inspectSources(scaleText: String, mappingText: String) -> Result<Self, ValidationIssue> {
        var stage = SourceStage.scale
        do {
            let scale = try ScalaKeyboardImport.scale(scaleText)
            stage = .mapping
            let mapping = try ScalaKeyboardImport.mapping(mappingText, scale: scale)
            stage = .calibration
            let preview = try ScalaKeyboardPreview(scale: scale, mapping: mapping)
            return .success(Self(scaleText: scaleText, mappingText: mappingText, preview: preview))
        } catch {
            return .failure(.source(stage: stage, reason: (error as? ScalaKeyboardImport.Failure) ?? .malformed))
        }
    }

    public init(scaleText: String, mappingText: String) throws {
        switch Self.inspectSources(scaleText: scaleText, mappingText: mappingText) {
        case .success(let profile): self = profile
        case .failure(let issue): throw issue.legacyError
        }
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, scale: scaleText, mapping: mappingText))
        guard data.count <= Self.maximumBytes else { throw Failure.invalidEnvelope }
        return data
    }

    /// The envelope is deliberately flat and UTF-8 only. Scan decoded keys
    /// before Foundation decoding, which may otherwise choose a different
    /// occurrence of a duplicate key than JSONSerialization does.
    private static func hasUniqueFields(_ data: Data) -> Bool {
        guard data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else { return false }
        let bytes = Array(data)
        var i = 0
        func space() {
            while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
        }
        func take(_ byte: UInt8) -> Bool {
            space()
            guard i < bytes.count, bytes[i] == byte else { return false }
            i += 1; return true
        }
        func stringToken() -> Data? {
            space()
            let start = i
            guard take(34) else { return nil }
            while i < bytes.count {
                let byte = bytes[i]; i += 1
                if byte == 34 { return Data(bytes[start..<i]) }
                if byte == 92 {
                    guard i < bytes.count else { return nil }
                    i += 1
                } else if byte < 32 { return nil }
            }
            return nil
        }
        guard take(123) else { return false }
        var seen = Set<String>()
        for field in 0..<3 {
            if field > 0 && !take(44) { return false }
            guard let token = stringToken(),
                  let key = try? JSONDecoder().decode(String.self, from: token),
                  ["version", "scale", "mapping"].contains(key),
                  seen.insert(key).inserted, take(58) else { return false }
            if key == "version" {
                space()
                let start = i
                if i < bytes.count && bytes[i] == 45 { i += 1 }
                let digits = i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                guard i > digits, i - start <= 20 else { return false }
                // Require integer syntax, not floats or exponents.
            } else if stringToken() == nil { return false }
        }
        guard take(125) else { return false }
        space()
        return i == bytes.count && seen.count == 3
    }

    /// Envelope and source failures remain distinct. No automatic repair,
    /// activation, or mutation of a previously valid profile occurs.
    public static func inspectData(_ data: Data) -> Result<Self, ValidationIssue> {
        guard hasUniqueFields(data),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure(.invalidEnvelope)
        }
        guard envelope.version == 1 else { return .failure(.unsupportedVersion) }
        return inspectSources(scaleText: envelope.scale, mappingText: envelope.mapping)
    }

    public static func importData(_ data: Data) throws -> Self {
        switch inspectData(data) {
        case .success(let profile): return profile
        case .failure(let issue): throw issue.legacyError
        }
    }
}
