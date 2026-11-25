/// Output splitting deliberately preserves the single router and its
/// first-on/last-off ownership. Different output policies must not share
/// a channel: reconciled commands carry a destination, not source identity.
public struct GamepadOutputSelection: Equatable, Sendable {
    public var slot1: MusicalOutput
    public var slot2: MusicalOutput
    public init(slot1:MusicalOutput = .midi,slot2:MusicalOutput = .haptic) {
        self.slot1 = slot1
        self.slot2 = slot2
    }
}

public struct GamepadOutputPlan: Equatable, Sendable {
    private let channels: [Int:MusicalOutput]
    public init?(patch:InstrumentPatch,selection:GamepadOutputSelection) {
        guard GamepadHapticVoices.supports(patch),
              Set(patch.routes.map(\.source)) == GamepadFrame.sources else { return nil }
        var next: [Int:MusicalOutput] = [:]
        for route in patch.routes {
            let output = route.source == .gamepad1 ? selection.slot1 : selection.slot2
            let channel = route.destination.channel
            if let previous = next[channel], previous != output { return nil }
            next[channel] = output
        }
        channels = next
    }
    public var hasMIDI: Bool { channels.values.contains { $0.sendsMIDI } }
    public var hasHaptics: Bool { channels.values.contains { $0.sendsHaptics } }
    public func sendsMIDI(_ destination:SensorDestination) -> Bool {
        destination.isValid && channels[destination.channel]?.sendsMIDI == true
    }
    public func sendsHaptics(_ destination:SensorDestination) -> Bool {
        destination.isValid && channels[destination.channel]?.sendsHaptics == true
    }
}
