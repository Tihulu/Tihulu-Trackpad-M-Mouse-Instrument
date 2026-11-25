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
}
