import Foundation

/// Pure admission check for an explicitly requested group start.
/// A stale or unconfirmed tuned request must never fall back to standard MIDI.
/// Runtime still owns physical bindings, port registration, and cleanup.
public struct PerformanceGroupActivationPlan: Sendable {
    public enum Mode: Equatable, Sendable {
        case standard
        case tuned(PerformanceGroupTuningConfiguration)
    }
    public enum AdmissionError: Error, Equatable {
        case unsupportedProfile, layeringNotApproved, cleanupRequired
        case tuningNotConfirmed, tuningRequiresClosedPorts, remoteModeMismatch
    }

    public let profile: PerformanceGroupProfile
    public let mode: Mode
    public let allowLayering: Bool
    public let allowRemote: Bool
    public var tuning: [UUID:PerformanceGroupTuningPlan.Specification] {
        switch mode {
        case .standard: return [:]
        case .tuned(let configuration): return configuration.tuning
        }
    }

    public init(profile:PerformanceGroupProfile,mode:Mode,
                allowLayering:Bool,confirmedTuning:Bool,
                registeredIDs:Set<UUID>,cleanupIDs:Set<UUID>,
                pendingDisposalCount:Int, allowRemote:Bool = false) throws {
        guard cleanupIDs.isEmpty, pendingDisposalCount == 0 else {
            throw AdmissionError.cleanupRequired
        }
        let hasRemote = profile.groups.contains { group in
            group.patch.routes.contains { $0.source.isGroupRemote }
        }
        guard hasRemote == allowRemote else { throw AdmissionError.remoteModeMismatch }
        guard PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,
                                                       allowScalars:true,allowCamera:true,allowRemote:allowRemote)
        else { throw AdmissionError.unsupportedProfile }
        guard allowLayering || profile.layeredInputs.isEmpty else {
            throw AdmissionError.layeringNotApproved
        }
        if case .tuned(let configuration) = mode {
            guard confirmedTuning else { throw AdmissionError.tuningNotConfirmed }
            guard registeredIDs.isEmpty else { throw AdmissionError.tuningRequiresClosedPorts }
            _ = try configuration.plan(matching:profile)
        }
        self.profile = profile
        self.mode = mode
        self.allowLayering = allowLayering
        self.allowRemote = allowRemote
    }
}


/// Offline quick setup diagnostics. No device probing, permission request,
/// port creation or output. Actual Start still performs runtime admission.
public struct PerformanceGroupQuickReadiness:Sendable {
    public enum Blocker:Equatable,Sendable {
        case invalidProfile,emptyProfile,unsupportedMappings,portIdentityConflict
        case layeringNeedsConsent,mobileSetupRequired,mobileDisabled
        case controllerMissing(SensorSource),controllerDuplicate(SensorSource)
    }
    public let blockers:[Blocker]
    public var readyForLocalStart:Bool { blockers.isEmpty }

    public init(profile:PerformanceGroupProfile,selected:[SensorSource:UUID],
                available:Set<UUID>,allowLayering:Bool=false,mobileEnabled:Bool=false) {
        var issues:[Blocker]=[]
        let routes=profile.groups.flatMap { $0.patch.routes }
        if !profile.isValid { issues.append(.invalidProfile) }
        else if routes.isEmpty { issues.append(.emptyProfile) }
        else {
            if !PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,
                                                         allowScalars:true,allowCamera:true,allowRemote:true) {
                issues.append(.unsupportedMappings)
            }
            if (try? PerformanceGroupEndpointPlan(profile:profile)) == nil { issues.append(.portIdentityConflict) }
            if !allowLayering && !profile.layeredInputs.isEmpty { issues.append(.layeringNeedsConsent) }
        }
        if routes.contains(where:{$0.source.isGroupRemote}) {
            issues.append(mobileEnabled ? .mobileSetupRequired : .mobileDisabled)
        }
        let required=Set(routes.map(\.source)).intersection(GamepadFrame.sources)
        var used=Set<UUID>()
        for source in GamepadFrame.orderedSources where required.contains(source) {
            guard let id=selected[source],available.contains(id) else {
                issues.append(.controllerMissing(source));continue
            }
            if !used.insert(id).inserted { issues.append(.controllerDuplicate(source)) }
        }
        blockers=issues
    }
}
