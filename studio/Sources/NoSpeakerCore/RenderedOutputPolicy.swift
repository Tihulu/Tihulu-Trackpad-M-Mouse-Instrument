/// Conservative arbitration between legacy rendered playback and legacy live
/// motor producers. Dedicated MIDI-only Builder/Sequencer/Chord endpoints
/// are deliberately not part of this motor policy.
public struct RenderedOutputPolicy: Equatable, Sendable {
    public var rendered: Bool
    public var touch: Bool
    public var bridge: Bool
    public var helper: Bool
    public var hinge: Bool
    public init(rendered: Bool, touch: Bool, bridge: Bool, helper: Bool, hinge: Bool) {
        self.rendered = rendered; self.touch = touch; self.bridge = bridge
        self.helper = helper; self.hinge = hinge
    }
    public var permitsRenderedStart: Bool { !touch && !bridge && !helper && !hinge }
    public var permitsLiveStart: Bool { !rendered }
    public var needsRenderedStop: Bool { rendered }
}
