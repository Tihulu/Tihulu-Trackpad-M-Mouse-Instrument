import Foundation

/// Text edits are deliberately distinct from an applied, validated tuning.
/// Starting, exporting and replacing a configuration must not ignore edits.
public struct PerformanceGroupTuningDraft: Equatable, Sendable {
    public private(set) var selectedID: UUID?
    public var scaleName = "Custom scale"
    public var degrees = "0, 180, 400, 500, 700, 900, 1100"
    public var rootText = "60"

    private var baselineName = "Custom scale"
    private var baselineDegrees = "0, 180, 400, 500, 700, 900, 1100"
    private var baselineRoot = "60"

    public init() {}

    public var isDirty: Bool {
        scaleName != baselineName || degrees != baselineDegrees || rootText != baselineRoot
    }

    /// An ordinary selection cannot discard unapplied text.
    @discardableResult
    public mutating func select(_ id:UUID?,configuration:PerformanceGroupTuningConfiguration?) -> Bool {
        guard !isDirty else { return false }
        load(id,configuration:configuration)
        return true
    }

    /// Explicit user discard, successful application or successful import.
    public mutating func load(_ id:UUID?,configuration:PerformanceGroupTuningConfiguration?) {
        self = Self()
        selectedID = id
        if let id, let specification = configuration?.tuning[id] {
            scaleName = specification.scale.name
            degrees = specification.scale.degreeCents.map { String($0) }.joined(separator:", ")
            rootText = String(specification.root)
        }
        baselineName = scaleName
        baselineDegrees = degrees
        baselineRoot = rootText
    }

    public enum DraftError: Error, Equatable { case missingGroup, invalidScaleOrRoot }

    /// Returns a new fully validated configuration; never mutates the current
    /// configuration or marks text clean when validation fails.
    public func applying(to profile:PerformanceGroupProfile,
                         configuration:PerformanceGroupTuningConfiguration?) throws -> PerformanceGroupTuningConfiguration {
        if let configuration { _ = try configuration.plan(matching:profile) }
        guard let selectedID, profile.groups.contains(where:{ $0.id == selectedID && !$0.patch.routes.isEmpty })
        else { throw DraftError.missingGroup }
        guard let root = Int(rootText.trimmingCharacters(in:.whitespacesAndNewlines)),
              (0...127).contains(root),
              let scale = CustomScale.fromDegreeCents(degrees,name:scaleName),
              scale.isMicrotonal else { throw DraftError.invalidScaleOrRoot }
        var next = configuration?.tuning ?? [:]
        next[selectedID] = .init(scale:scale,root:root)
        return try .init(profile:profile,tuning:next)
    }
}
