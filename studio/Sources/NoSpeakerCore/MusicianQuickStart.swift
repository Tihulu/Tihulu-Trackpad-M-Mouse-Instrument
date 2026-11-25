import Foundation

/// Ready-to-edit host patches, not connection or output permissions.
public enum MusicianQuickStart: String, CaseIterable, Identifiable, Sendable {
    case phoneDrums, phoneExpression, tabletExpression, controllerLead, controllerHelper, controllerDuo, mobileDuo, fullParty
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .phoneDrums: "Phone drums"
        case .phoneExpression: "Phone note surface"
        case .tabletExpression: "Tablet note surface"
        case .controllerLead: "Gamepad melody"
        case .controllerHelper: "Gamepad MIDI helper"
        case .controllerDuo: "Two-controller jam"
        case .mobileDuo: "Phone and tablet duo"
        case .fullParty: "Full Party Jam"
        }
    }
    public var instructions: String {
        switch self {
        case .phoneDrums: "One phone: drum pads on MIDI channel 10."
        case .phoneExpression: "One phone: C major note zones, sustain, MIDI channel 1. Choose Note strips on the paired page."
        case .tabletExpression: "One tablet: C major note zones, sustain, MIDI channel 2. Choose Note strips on the paired page."
        case .controllerLead: "One paired controller: A/B/X/Y melody, left X pitch bend, right Y filter and RT sustain, channel 4."
        case .controllerHelper: "One paired controller: RT sustain, LT wah, left X bend and right Y modulation, channel 1. Play notes from your separate DAW instrument."
        case .controllerDuo: "Two paired controllers: melody on channel 4, drums on channel 10."
        case .mobileDuo: "Phone drums on channel 10, tablet piano on channel 2."
        case .fullParty: "Phone drums, tablet piano, two controllers, Trackpad bass and local helpers. Both controller slots must be bound."
        }
    }
    public func patch() -> InstrumentPatch? {
        var routes: [SensorMapping]
        switch self {
        case .phoneDrums:
            routes = RemoteDrumPads.routes(source: .phone)
        case .phoneExpression, .tabletExpression:
            let source: SensorSource = self == .phoneExpression ? .phone : .tablet
            let channel = self == .phoneExpression ? 0 : 1
            guard let patch = try? MobileExpressionPreset.major.appending(
                to: InstrumentPatch(name: title), source: source, channel: channel, root: 48
            ), PhysicalPatchRuntime.supports(patch, allowRemote: true) else { return nil }
            return patch
        case .controllerLead:
            routes = GamepadFrame.Role.lead.routes(source: .gamepad1, channel: 3)
        case .controllerHelper:
            routes = GamepadFrame.Role.helper.routes(source: .gamepad1, channel: 0)
        case .controllerDuo:
            routes = GamepadFrame.Role.lead.routes(source: .gamepad1, channel: 3)
            routes += GamepadFrame.Role.drums.routes(source: .gamepad2, channel: 9)
        case .mobileDuo:
            routes = RemoteDrumPads.routes(source: .phone)
            routes += RemotePiano.routes(source: .tablet).map {
                var route = $0
                route.destination.channel = 1
                return route
            }
        case .fullParty:
            return PartyJamPreset.patch()
        }
        let patch = InstrumentPatch(name: title, routes: routes)
        return PhysicalPatchRuntime.supports(patch, allowRemote: true) ? patch : nil
    }
}
