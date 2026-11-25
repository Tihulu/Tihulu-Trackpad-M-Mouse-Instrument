import Foundation

/// A separate native admission policy, not an offline preview authorization.
/// Fixed-member and standard starts never select this plan implicitly.
public struct DynamicMPEActivationPlan: Sendable {
    public enum AdmissionError:Error,Equatable {
        case confirmationRequired, cleanupRequired, portsMustBeClosed, incompatibleMode, unsupportedProfile
    }
    public let preview:DynamicMPEPreview
    public let allowLayering:Bool

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification],
                confirmed:Bool,allowLayering:Bool,registeredIDs:Set<UUID>,cleanupIDs:Set<UUID>,
                pendingDisposalCount:Int,allowSurfaces:Bool = false,allowScalars:Bool = false,
                allowCamera:Bool = false,allowRemote:Bool = false,hapticGroups:Set<UUID> = [],
                allowDynamicHaptics:Bool = false) throws {
        guard confirmed else { throw AdmissionError.confirmationRequired }
        guard cleanupIDs.isEmpty,pendingDisposalCount == 0 else { throw AdmissionError.cleanupRequired }
        guard registeredIDs.isEmpty else { throw AdmissionError.portsMustBeClosed }
        guard !allowRemote,hapticGroups.isEmpty || allowDynamicHaptics else { throw AdmissionError.incompatibleMode }
        guard PerformanceGroupGamepadSession.supports(profile,allowSurfaces:allowSurfaces,
            allowScalars:allowScalars,allowCamera:allowCamera),
            allowLayering || profile.layeredInputs.isEmpty else { throw AdmissionError.unsupportedProfile }
        preview = try .init(profile:profile,tuning:tuning)
        if !hapticGroups.isEmpty {
            _ = try PerformanceGroupHapticProjection(preparedDynamic:preview,selected:hapticGroups)
        }
        self.allowLayering = allowLayering
    }
}
