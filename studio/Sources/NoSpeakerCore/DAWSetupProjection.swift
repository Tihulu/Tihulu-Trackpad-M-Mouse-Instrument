/// Read-only projection of Builder output choices. No MIDI or hardware access.
public struct DAWSetupProjection: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case invalid, disabled, standard, tunedAir
    }
    public struct Channel: Equatable, Sendable, Identifiable {
        public let number: Int
        public let notes: [String]
        public let controls: [String]
        public var id: Int { number }
    }
    public let status: Status
    public let channels: [Channel]
    public var port: String? {
        switch status {
        case .standard: return "TIHULU Instrument Builder"
        case .tunedAir: return "TIHULU Air Strings MPE"
        default: return nil
        }
    }

    public init(patch: InstrumentPatch, sendMIDI: Bool, tunedAir: Bool = false,
                splitRequested: Bool = false, splitPlan: GamepadOutputPlan? = nil) {
        guard patch.isValid, !patch.routes.isEmpty,
              !splitRequested || (splitPlan != nil && !tunedAir) else {
            status = .invalid; channels = []; return
        }
        let routes = patch.routes.filter {
            splitRequested ? (splitPlan?.sendsMIDI($0.destination) == true) : sendMIDI
        }
        guard !routes.isEmpty else {
            status = .disabled; channels = []; return
        }
        // Tuned Air translates logical destinations to member channels.
        // Never publish logical channel numbers as wire addresses.
        if tunedAir {
            status = .tunedAir; channels = []; return
        }
        status = .standard
        let grouped = Dictionary(grouping: routes, by: { $0.destination.channel })
        channels = grouped.keys.sorted().map { key in
            let routes = grouped[key] ?? []
            let notes = Set(routes.filter { $0.destination.kind == .note }.map { $0.source.rawValue })
            let controls = Set(routes.filter { $0.destination.kind != .note }.map { route in
                let target = route.destination
                let label: String
                switch target.kind {
                case .controlChange: label = "CC " + String(target.number)
                case .sustain: label = "CC 64 (Sustain)"
                case .pitchBend: label = "Pitch Bend"
                default: label = target.kind.rawValue + " " + String(target.number)
                }
                return route.source.rawValue + " / " + route.signal.rawValue + ": " + label
            })
            return Channel(number: key + 1, notes: notes.sorted(), controls: controls.sorted())
        }
    }
}
