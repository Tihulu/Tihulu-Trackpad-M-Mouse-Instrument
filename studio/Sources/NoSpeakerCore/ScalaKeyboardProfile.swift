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

    public init(scaleText: String, mappingText: String) throws {
        let scale = try ScalaKeyboardImport.scale(scaleText)
        let mapping = try ScalaKeyboardImport.mapping(mappingText, scale: scale)
        self.preview = try ScalaKeyboardPreview(scale: scale, mapping: mapping)
        self.scaleText = scaleText
        self.mappingText = mappingText
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

    public static func importData(_ data: Data) throws -> Self {
        guard hasUniqueFields(data),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.invalidEnvelope
        }
        guard envelope.version == 1 else { throw Failure.unsupportedVersion }
        return try Self(scaleText: envelope.scale, mappingText: envelope.mapping)
    }
}
