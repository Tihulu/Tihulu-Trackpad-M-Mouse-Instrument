import Foundation

/// Deliberately separate from the fixed-member tuning archive. An offline
/// preview is not a start authorization and never promises a free channel.
public struct DynamicMPEPreview: Sendable {
    public struct Route:Equatable,Sendable {
        public let mappingID:String
        public let source:SensorSource
        public let signal:SensorSignal
        public let logical:SensorDestination
        public let possibleChannels:[Int]
    }
    public struct Group:Identifiable,Sendable {
        public let id:UUID
        public let name:String
        public let port:String
        public let plan:DynamicMPEPoolPlan
        public let routes:[Route]
    }
    public let profile:PerformanceGroupProfile
    public let tuning:[UUID:PerformanceGroupTuningPlan.Specification]
    public let groups:[Group]

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification]) throws {
        let delivery = try DynamicMPEGroupDelivery(profile:profile,tuning:tuning,allowLayering:true)
        self.profile = profile
        self.tuning = tuning
        groups = try profile.groups.filter { !$0.patch.routes.isEmpty }.map { group in
            guard let plan = delivery.plans[group.id] else { throw MIDIClipError.invalidClip }
            let routes = try group.patch.routes.map { route in
                let channels = plan.possibleChannels(for:route.destination)
                guard !channels.isEmpty else { throw MIDIClipError.invalidClip }
                return Route(mappingID:route.id,source:route.source,signal:route.signal,logical:route.destination,possibleChannels:channels)
            }
            return Group(id:group.id,name:group.name,port:group.plannedPortName,plan:plan,routes:routes)
        }
    }

    public static func specification(name:String,degrees:String,rootText:String) throws -> PerformanceGroupTuningPlan.Specification {
        guard let root = Int(rootText.trimmingCharacters(in:.whitespacesAndNewlines)),(0...127).contains(root) else {
            throw MIDIClipError.invalidNote
        }
        guard let scale = CustomScale.fromDegreeCents(degrees,name:name),scale.isMicrotonal else { throw MIDIClipError.invalidClip }
        return .init(scale:scale,root:root)
    }
}
