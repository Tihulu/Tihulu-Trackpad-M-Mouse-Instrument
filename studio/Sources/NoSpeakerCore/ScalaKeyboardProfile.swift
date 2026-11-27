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

    public static func importData(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "scale", "mapping"],
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.invalidEnvelope
        }
        guard envelope.version == 1 else { throw Failure.unsupportedVersion }
        return try Self(scaleText: envelope.scale, mappingText: envelope.mapping)
    }
}
