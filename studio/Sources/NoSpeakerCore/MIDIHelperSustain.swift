import Foundation

/// Input modes are explicit: a contact is not a Force Touch pressure reading.
/// Physical clicks are provided separately by the macOS event monitor.
public enum TrackpadSustainGesture: String, CaseIterable, Identifiable, Sendable {
    case contactThreshold = "Contact Threshold"
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"
    case physicalClickHold = "Physical Click Hold"
    case physicalClickToggle = "Physical Click Toggle"

    public var id: String { rawValue }
}

public enum MagicMouseSustainGesture: String, CaseIterable, Identifiable, Sendable {
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"
    case physicalClickHold = "Physical Click Hold"
    case physicalClickToggle = "Physical Click Toggle"

    public var id: String { rawValue }
}

/// A single set of sustain choices is reusable in MIDI Helper and Touch Instrument.
public struct MIDIHelperSustainSettings: Sendable, Equatable {
    public var trackpadEnabled: Bool
    public var trackpadContactThreshold: Double
    public var trackpadGesture: TrackpadSustainGesture
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
        self.trackpadContactThreshold = trackpadContactThreshold
        self.trackpadGesture = trackpadGesture
        self.magicMouseEnabled = magicMouseEnabled
        self.magicMouseGesture = magicMouseGesture
    }

    public var needsPhysicalClicks: Bool {
        (trackpadEnabled &&
            (trackpadGesture == .physicalClickHold || trackpadGesture == .physicalClickToggle)) ||
        (magicMouseEnabled &&
            (magicMouseGesture == .physicalClickHold || magicMouseGesture == .physicalClickToggle))
    }
}

public struct MIDIHelperSustainSnapshot: Sendable, Equatable {
    public var trackpadActive: Bool
    public var magicMouseActive: Bool

    public init(trackpadActive: Bool = false, magicMouseActive: Bool = false) {
        self.trackpadActive = trackpadActive
        self.magicMouseActive = magicMouseActive
    }

    /// Either surface may hold sustain; lifting one never cancels the other.
    public var isActive: Bool { trackpadActive || magicMouseActive }
}

public struct MIDIHelperAssignments: Sendable, Equatable {
    public var vibrato: Bool
    public var pitchBend: Bool
    public var expression: Bool

    public init(vibrato: Bool = true, pitchBend: Bool = true, expression: Bool = true) {
        self.vibrato = vibrato
        self.pitchBend = pitchBend
        self.expression = expression
    }

    public static var hybrid: Self { .init(vibrato: true, pitchBend: true, expression: true) }
}

/// Hardware-independent sustain logic; caller supplies independent physical
/// click signals only when a click can be confidently assigned to a surface.
public struct MIDIHelperSustainState: Sendable {
    private var trackpadHeld = false
    private var trackpadWasTouching = false
    private var trackpadWasClicking = false
    private var trackpadLatched = false
    private var mouseWasTouching = false
    private var mouseWasClicking = false
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
        let threshold = max(0.05, min(1, settings.trackpadContactThreshold))
        let contactSize = trackpadContactSizes
            .filter { $0.isFinite }
            .map { min(1, max(0, $0)) }
            .max() ?? 0
        let trackpadTouching = !trackpadContactSizes.isEmpty

        let trackpadActive: Bool
        if !settings.trackpadEnabled {
            trackpadHeld = false
            trackpadLatched = false
            trackpadActive = false
        } else {
            switch settings.trackpadGesture {
            case .contactThreshold:
                let releaseThreshold = max(0, threshold - 0.08)
                trackpadHeld = trackpadTouching && (trackpadHeld
                    ? contactSize >= releaseThreshold : contactSize >= threshold)
                trackpadActive = trackpadHeld
            case .touchHold:
                trackpadLatched = false
                trackpadActive = trackpadTouching
            case .tapToggle:
                if trackpadTouching && !trackpadWasTouching {
                    trackpadLatched.toggle()
                }
                trackpadActive = trackpadLatched
            case .physicalClickHold:
                trackpadLatched = false
                trackpadActive = trackpadClickDown
            case .physicalClickToggle:
                if trackpadClickDown && !trackpadWasClicking {
                    trackpadLatched.toggle()
                }
                trackpadActive = trackpadLatched
            }
        }

        let mouseActive: Bool
        if !settings.magicMouseEnabled {
            mouseLatched = false
            mouseActive = false
        } else {
            switch settings.magicMouseGesture {
            case .touchHold:
                mouseLatched = false
                mouseActive = magicMouseTouching
            case .tapToggle:
                if magicMouseTouching && !mouseWasTouching {
                    mouseLatched.toggle()
                }
                mouseActive = mouseLatched
            case .physicalClickHold:
                mouseLatched = false
                mouseActive = magicMouseClickDown
            case .physicalClickToggle:
                if magicMouseClickDown && !mouseWasClicking {
                    mouseLatched.toggle()
                }
                mouseActive = mouseLatched
            }
        }

        trackpadWasTouching = trackpadTouching
        trackpadWasClicking = trackpadClickDown
        mouseWasTouching = magicMouseTouching
        mouseWasClicking = magicMouseClickDown
        snapshot = .init(trackpadActive: trackpadActive, magicMouseActive: mouseActive)
        return snapshot
    }

    public mutating func reset() {
        trackpadHeld = false
        trackpadWasTouching = false
        trackpadWasClicking = false
        trackpadLatched = false
        mouseWasTouching = false
        mouseWasClicking = false
        mouseLatched = false
        snapshot = .init()
    }
}
