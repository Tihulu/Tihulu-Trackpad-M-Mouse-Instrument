/// Standard MIDI only. MPE needs its own endpoint/channel allocation plan.
public struct DAWSurfaceChannels: Sendable, Equatable {
    public let trackpad: Int
    public let magicMouse: Int
    public init?(trackpad: Int, magicMouse: Int) {
        guard (0...15).contains(trackpad), (0...15).contains(magicMouse),
              trackpad != magicMouse else { return nil }
        self.trackpad = trackpad
        self.magicMouse = magicMouse
    }
    public var all: Set<Int> { [trackpad,magicMouse] }

    /// Shared is the legacy behavior. Independent mode maps each pedal to
    /// its own fixed channel, including when no note is currently held.
    public func sustainTargets(_ snapshot: MIDIHelperSustainSnapshot, independent: Bool) -> Set<Int> {
        guard independent else { return snapshot.isActive ? all : [] }
        var result: Set<Int> = []
        if snapshot.trackpadActive { result.insert(trackpad) }
        if snapshot.magicMouseActive { result.insert(magicMouse) }
        return result
    }
}
