public enum DAWRoutingOverview {
    public struct Row: Equatable, Sendable, Identifiable {
        public let channel: Int
        public let noteSources: [SensorSource]
        public let controlSources: [SensorSource]
        public var id: Int { channel }
        public var sharesNotes: Bool { noteSources.count > 1 }
    }

    /// Host-side patch projection; no discovery, connection or MIDI side effects.
    /// Control-only sources may deliberately accompany another instrument.
    public static func rows(for patch: InstrumentPatch) -> [Row] {
        guard patch.isValid else { return [] }
        return Dictionary(grouping:patch.routes,by:{ $0.destination.channel }).keys.sorted().map { channel in
            let routes = patch.routes.filter { $0.destination.channel == channel }
            let notes = Set(routes.filter { $0.destination.kind == .note }.map(\.source))
            let controls = Set(routes.filter { $0.destination.kind != .note }.map(\.source))
            return Row(channel:channel,noteSources:notes.sorted { $0.rawValue < $1.rawValue },
                controlSources:controls.sorted { $0.rawValue < $1.rawValue })
        }
    }
}
