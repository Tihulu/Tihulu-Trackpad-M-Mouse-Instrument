import Foundation

/// Pure editor utilities. Searching never changes route order, identity or
/// playback. Preset insertion is atomic and preserves all existing fan-out.
public enum BuilderRouteTools {
    public enum MobilePreset: String, CaseIterable, Identifiable, Sendable {
        case drums, piano, pedals
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .drums: "Drum pads"
            case .piano: "Piano keys and sustain"
            case .pedals: "Pedalboard"
            }
        }
        public var signals: [SensorSignal] {
            switch self {
            case .drums: RemoteDrumPads.signals
            case .piano: RemotePiano.signals
            case .pedals: RemotePedalboard.signals
            }
        }
        private func defaults(source: SensorSource) -> [SensorMapping] {
            switch self {
            case .drums: RemoteDrumPads.routes(source:source)
            case .piano: RemotePiano.routes(source:source)
            case .pedals: RemotePedalboard.routes(source:source)
            }
        }
        public func missingCount(in patch: InstrumentPatch, source: SensorSource) -> Int {
            guard source == .phone || source == .tablet else { return 0 }
            let existing = Set(patch.routes.filter { $0.source == source }.map(\.signal))
            return signals.filter { !existing.contains($0) }.count
        }
        public func appending(to patch: InstrumentPatch, source: SensorSource) throws -> InstrumentPatch {
            guard source == .phone || source == .tablet else { throw SensorRouterError.invalidMappings }
            let existing = Set(patch.routes.filter { $0.source == source }.map(\.signal))
            let count = missingCount(in:patch,source:source)
            guard patch.isValid, count <= SensorRouter.maxMappings - patch.routes.count else {
                throw SensorRouterError.invalidMappings
            }
            var result = patch
            result.routes += defaults(source:source).filter { !existing.contains($0.signal) }
            guard result.isValid else { throw SensorRouterError.invalidMappings }
            return result
        }
    }

    /// Descriptive role of configured routes, not a hardware capability
    /// or activation permission. A source may play notes and helper controls.
    public struct SourceRole: Equatable, Sendable, Identifiable {
        public enum Role:String,Sendable {case instrument="Instrument",helper="Helper",hybrid="Hybrid"}
        public let source:SensorSource
        public let role:Role
        public let noteRoutes:Int
        public let helperRoutes:Int
        public var id:SensorSource{source}
    }
    public static func sourceRoles(in patch:InstrumentPatch)->[SourceRole] {
        SensorSource.allCases.compactMap { source in
            let routes=patch.routes.filter{$0.source==source}
            guard !routes.isEmpty else{return nil}
            let notes=routes.filter{$0.destination.kind == .note}.count
            let helpers=routes.count-notes
            return SourceRole(source:source,role:notes==0 ? .helper : helpers==0 ? .instrument : .hybrid,noteRoutes:notes,helperRoutes:helpers)
        }
    }

    public static func summary(_ route: SensorMapping) -> String {
        let d = route.destination
        let target: String
        switch d.kind {
        case .note: target = "Note \(d.number)"
        case .controlChange: target = "CC \(d.number)"
        case .pitchBend: target = "Pitch bend"
        case .sustain: target = "Sustain CC64"
        }
        return "\(route.source.rawValue) · \(route.signal.rawValue) → Ch \(d.channel+1) · \(target)"
    }

    public static func visibleIDs(in patch: InstrumentPatch, source: SensorSource?, query: String) -> [String] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return patch.routes.filter { route in
            guard source == nil || source == route.source else { return false }
            let label = patch.performanceLayout?.widgets.first { $0.source == route.source && $0.signal == route.signal }?.label ?? ""
            let haystack = summary(route) + " " + label + " " + route.destination.kind.rawValue
            return terms.allSatisfy { haystack.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) != nil }
        }.map(\.id)
    }
}
