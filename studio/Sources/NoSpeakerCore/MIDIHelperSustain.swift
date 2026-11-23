import Foundation

/// A touch/contact gesture does not require an actual click.
/// A hardware click gesture is distinct from contact size / force.
public enum TrackpadSustainGesture: String, CaseIterable, Identifiable, Sendable {
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"
    case clickHold = "Click Hold"
    case clickToggle = "Click Toggle"
    case contactThreshold = "Contact Threshold"

    public var id: String { rawValue }
}

public enum MagicMouseSustainGesture: String, CaseIterable, Identifiable, Sendable {
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"
    case clickHold = "Click Hold"
    case clickToggle = "Click Toggle"

    public var id: String { rawValue }
}

public struct MIDIHelperSustainSettings: Sendable, Equatable {
    public var trackpadEnabled: Bool
    public var trackpadGesture: TrackpadSustainGesture
    public var trackpadContactThreshold: Double
    public var magicMouseEnabled: Bool
    public var magicMouseGesture: MagicMouseSustainGesture

    public init(
        trackpadEnabled: Bool = false,
        trackpadContactThreshold: Double = 0.55,
        magicMouseEnabled: Bool = false,
        magicMouseGesture: MagicMouseSustainGesture = .touchHold,
        trackpadGesture: TrackpadSustainGesture = .contactThreshold
    ) {
        self.trackpadEnabled = trackpadEnabled
        self.trackpadGesture = trackpadGesture
        self.trackpadContactThreshold = trackpadContactThreshold
        self.magicMouseEnabled = magicMouseEnabled
        self.magicMouseGesture = magicMouseGesture
    }
}

public struct MIDIHelperSustainSnapshot: Sendable, Equatable {
    public var trackpadActive: Bool
    public var magicMouseActive: Bool

    public init(trackpadActive: Bool = false, magicMouseActive: Bool = false) {
        self.trackpadActive = trackpadActive
        self.magicMouseActive = magicMouseActive
    }

    /// Either surface may hold sustain; releasing one cannot release the other.
    public var isActive: Bool { trackpadActive || magicMouseActive }
}

/// Pure, hardware-independent sustain state machine shared by MIDI Helper and
/// Touch Instrument. Contact-size is a proxy, not calibrated Force Touch force.
/// Click events must be attributed to a surface by the macOS input adapter.
public struct MIDIHelperSustainState: Sendable {
    private var trackpadThresholdHeld = false
    private var trackpadWasTouching = false
    private var trackpadWasClicked = false
    private var trackpadLatched = false
    private var mouseWasTouching = false
    private var mouseWasClicked = false
    private var mouseLatched = false

    public private(set) var snapshot = MIDIHelperSustainSnapshot()

    public init() {}

    public mutating func update(
        trackpadContactSizes: [Double],
        magicMouseTouching: Bool,
        settings: MIDIHelperSustainSettings,
        trackpadClickDown: Bool = false,
        magicMouseClickDown: Bool = false
    ) -> MIDIHelperSustainSnapshot {
        let threshold = min(1.0, max(0.05, settings.trackpadContactThreshold))
        let contactSize = trackpadContactSizes
            .filter(\.isFinite)
            .map { min(1.0, max(0.0, $0)) }
            .max() ?? 0
        let trackpadTouching = !trackpadContactSizes.isEmpty

        let trackpadActive: Bool
        if settings.trackpadEnabled {
            switch settings.trackpadGesture {
            case .touchHold:
                trackpadLatched = false
                trackpadActive = trackpadTouching
            case .tapToggle:
                if trackpadTouching && !trackpadWasTouching {
                    trackpadLatched.toggle()
                }
                trackpadActive = trackpadLatched
            case .clickHold:
                trackpadLatched = false
                trackpadActive = trackpadClickDown
            case .clickToggle:
                if trackpadClickDown && !trackpadWasClicked {
                    trackpadLatched.toggle()
                }
                trackpadActive = trackpadLatched
            case .contactThreshold:
                trackpadLatched = false
                if trackpadTouching {
                    let releaseThreshold = max(0, threshold - 0.08)
                    trackpadThresholdHeld = trackpadThresholdHeld
                        ? contactSize >= releaseThreshold
                        : contactSize >= threshold
                } else {
                    trackpadThresholdHeld = false
                }
                trackpadActive = trackpadThresholdHeld
            }
        } else {
            trackpadLatched = false
            trackpadThresholdHeld = false
            trackpadActive = false
        }

        let mouseActive: Bool
        if settings.magicMouseEnabled {
            switch settings.magicMouseGesture {
            case .touchHold:
                mouseLatched = false
                mouseActive = magicMouseTouching
            case .tapToggle:
                if magicMouseTouching && !mouseWasTouching {
                    mouseLatched.toggle()
                }
                mouseActive = mouseLatched
            case .clickHold:
                mouseLatched = false
                mouseActive = magicMouseClickDown
            case .clickToggle:
                if magicMouseClickDown && !mouseWasClicked {
                    mouseLatched.toggle()
                }
                mouseActive = mouseLatched
            }
        } else {
            mouseLatched = false
            mouseActive = false
        }

        trackpadWasTouching = trackpadTouching
        trackpadWasClicked = trackpadClickDown
        mouseWasTouching = magicMouseTouching
        mouseWasClicked = magicMouseClickDown
        snapshot = .init(trackpadActive: trackpadActive, magicMouseActive: mouseActive)
        return snapshot
    }

    public mutating func reset() {
        trackpadThresholdHeld = false
        trackpadWasTouching = false
        trackpadWasClicked = false
        trackpadLatched = false
        mouseWasTouching = false
        mouseWasClicked = false
        mouseLatched = false
        snapshot = .init()
    }
}
