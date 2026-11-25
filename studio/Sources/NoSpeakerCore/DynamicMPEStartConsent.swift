import Foundation

/// Exact inputs reviewed at the confirmation boundary. An editor must
/// compare this snapshot to current values immediately before Start.
public struct DynamicMPEStartConsent:Equatable,Sendable {
    public let profile:PerformanceGroupProfile
    public let tuning:[UUID:PerformanceGroupTuningPlan.Specification]
    public let archive:Data
    public let controllers:[SensorSource:UUID]
    public let allowLayering:Bool
    public let cameraID:String
    public let cameraOrientation:AirControlOrientation
    public let cameraMirror:Bool
    public let mouseOrientation:SurfaceOrientation

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification],
                archive:Data,controllers:[SensorSource:UUID],allowLayering:Bool,cameraID:String,
                cameraOrientation:AirControlOrientation,cameraMirror:Bool,mouseOrientation:SurfaceOrientation) {
        self.profile = profile; self.tuning = tuning; self.archive = archive
        self.controllers = controllers; self.allowLayering = allowLayering
        self.cameraID = cameraID; self.cameraOrientation = cameraOrientation
        self.cameraMirror = cameraMirror; self.mouseOrientation = mouseOrientation
    }
}
