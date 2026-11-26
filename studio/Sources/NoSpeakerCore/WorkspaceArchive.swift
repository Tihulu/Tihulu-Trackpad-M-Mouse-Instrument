import Foundation

public enum WorkspaceArchiveError: LocalizedError, Equatable {
    case tooLarge, unsupportedVersion, invalidName, invalidPayload
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Workspace exceeds the size limit."
        case .unsupportedVersion: "Unsupported workspace format or version."
        case .invalidName: "Invalid workspace name."
        case .invalidPayload: "Workspace settings are outside supported ranges."
        }
    }
}

/// A small, versioned local data envelope. Decoding never executes instructions
/// or starts an instrument; callers validate their concrete payload before use.
public enum WorkspaceArchive {
    public static let maximumBytes = 256 * 1024
    public static let format = "com.tihulu.instrument.workspace"
    public static let version = 1

    public struct Document<Payload: Codable>: Codable {
        public let format: String
        public let version: Int
        public let name: String
        public let payload: Payload
    }

    public static func encode<Payload: Codable>(name: String, payload: Payload) throws -> Data {
        guard validName(name) else { throw WorkspaceArchiveError.invalidName }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(format: format, version: version, name: name, payload: payload))
        guard data.count <= maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        return data
    }

    public static func decode<Payload: Codable>(_ type: Payload.Type, from data: Data) throws -> Document<Payload> {
        guard data.count <= maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        let doc = try JSONDecoder().decode(Document<Payload>.self, from: data)
        guard doc.format == format, doc.version == version else { throw WorkspaceArchiveError.unsupportedVersion }
        guard validName(doc.name) else { throw WorkspaceArchiveError.invalidName }
        return doc
    }

    /// Read at most the archive limit plus one sentinel byte. Importers
    /// must reject oversized files, not silently decode a truncated prefix.
    /// Ordinary local files only; no network URLs or directory reads.
    public static func readFile(at url:URL) throws -> Data {
        guard url.isFileURL,try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle=try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        var data=Data()
        while data.count<=maximumBytes {
            let remaining=min(65536,maximumBytes+1-data.count)
            guard let chunk=try handle.read(upToCount:remaining),!chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count<=maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        return data
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= 256 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
