import Foundation

/// Separate versioned tuning document. A legacy workspace reader must not
/// interpret this as a standard-MIDI group archive. The selected tuning is
/// bound to exact group identities and patches, not display names/order.
public struct PerformanceGroupTuningConfiguration: Equatable, Sendable {
    public static let format = "com.tihulu.instrument.group-tuning"
    public static let version = 1
    public enum ConfigurationError: Error, Equatable {
        case staleProfile, duplicateGroup, unsupportedFormat
    }

    public let profile: PerformanceGroupProfile
    public let tuning: [UUID:PerformanceGroupTuningPlan.Specification]

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification]) throws {
        _ = try PerformanceGroupTuningPlan(profile:profile,tuning:tuning)
        self.profile = profile
        self.tuning = tuning
    }

    private struct Entry: Codable {
        let groupID: UUID
        let specification: PerformanceGroupTuningPlan.Specification
    }
    private struct Document: Codable {
        let format: String
        let version: Int
        let profile: PerformanceGroupProfile
        let entries: [Entry]
    }

    /// Renaming/reordering is harmless; changing any group's identity or
    /// patch requires explicit review and a new tuning document.
    public func plan(matching current:PerformanceGroupProfile) throws -> PerformanceGroupTuningPlan {
        guard current.isValid, profile.isValid,
              Dictionary(uniqueKeysWithValues:current.groups.map { ($0.id,$0.patch) }) ==
                Dictionary(uniqueKeysWithValues:profile.groups.map { ($0.id,$0.patch) })
        else { throw ConfigurationError.staleProfile }
        return try PerformanceGroupTuningPlan(profile:current,tuning:tuning)
    }

    public func archive() throws -> Data {
        _ = try plan(matching:profile)
        let entries = tuning.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            tuning[id].map { Entry(groupID:id,specification:$0) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(Document(format:Self.format,version:Self.version,
                                                profile:profile,entries:entries))
        guard data.count <= WorkspaceArchive.maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        return data
    }

    public static func read(_ data:Data,matching current:PerformanceGroupProfile) throws -> Self {
        guard data.count <= WorkspaceArchive.maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == ["format","version","profile","entries"]
        else { throw ConfigurationError.unsupportedFormat }
        let doc = try JSONDecoder().decode(Document.self,from:data)
        guard doc.format == format, doc.version == version else { throw ConfigurationError.unsupportedFormat }
        guard (1...PerformanceGroupProfile.maximumGroups).contains(doc.entries.count)
        else { throw WorkspaceArchiveError.invalidPayload }
        var tuning: [UUID:PerformanceGroupTuningPlan.Specification] = [:]
        for entry in doc.entries {
            guard tuning.updateValue(entry.specification,forKey:entry.groupID) == nil
            else { throw ConfigurationError.duplicateGroup }
        }
        let result = try Self(profile:doc.profile,tuning:tuning)
        _ = try result.plan(matching:current)
        return result
    }
}
