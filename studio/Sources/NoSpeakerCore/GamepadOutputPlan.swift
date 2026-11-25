/// Output splitting deliberately preserves the single router and its
/// first-on/last-off ownership. Different output policies must not share
/// a channel: reconciled commands carry a destination, not source identity.
public struct GamepadOutputSelection: Equatable, Sendable {
    public var slot1: MusicalOutput
    public var slot2: MusicalOutput
    public var slot3: MusicalOutput
    public var slot4: MusicalOutput
    public init(slot1:MusicalOutput = .midi,slot2:MusicalOutput = .haptic,
                slot3:MusicalOutput = .midi,slot4:MusicalOutput = .midi) {
        self.slot1 = slot1
        self.slot2 = slot2
        self.slot3 = slot3
        self.slot4 = slot4
    }
    public func output(for source:SensorSource) -> MusicalOutput? {
        switch source {
        case .gamepad1: return slot1
        case .gamepad2: return slot2
        case .gamepad3: return slot3
        case .gamepad4: return slot4
        default: return nil
        }
    }
    public mutating func setOutput(_ output:MusicalOutput,for source:SensorSource) {
        switch source {
        case .gamepad1: slot1 = output
        case .gamepad2: slot2 = output
        case .gamepad3: slot3 = output
        case .gamepad4: slot4 = output
        default: break
        }
    }
}

public struct GamepadOutputPlan: Equatable, Sendable {
    private let channels: [Int:MusicalOutput]
    public init?(patch:InstrumentPatch,selection:GamepadOutputSelection) {
        guard GamepadHapticVoices.supports(patch),
              Set(patch.routes.map(\.source)).count >= 2 else { return nil }
        var next: [Int:MusicalOutput] = [:]
        for route in patch.routes {
            guard let output = selection.output(for:route.source) else { return nil }
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
