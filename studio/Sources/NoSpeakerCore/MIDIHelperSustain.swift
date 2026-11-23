import Foundation

/// Magic Mouse does not expose Force Touch pressure. A gesture can either
/// sustain while the surface is touched or latch CC64 on each new touch session.
public enum MagicMouseSustainGesture: String, CaseIterable, Identifiable, Sendable {
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"

    public var id: String { rawValue }
}

public struct MIDIHelperSustainSettings: Sendable, Equatable {
    public var trackpadEnabled: Bool
    public var trackpadContactThreshold: Double
    public var magicMouseEnabled: Bool
    public var magicMouseGesture: MagicMouseSustainGesture

    public init(
        trackpadEnabled: Bool = false,
        trackpadContactThreshold: Double = 0.55,
        magicMouseEnabled: Bool = false,
        magicMouseGesture: MagicMouseSustainGesture = .touchHold
    ) {
        self.trackpadEnabled = trackpadEnabled
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

    /// If both surfaces are enabled, either may hold sustain without the other
    /// prematurely sending CC64 OFF.
    public var isActive: Bool { trackpadActive || magicMouseActive }
}

/// Pure, hardware-independent sustain logic for testing in Swift core CI.
/// Trackpad strength is a normalized contact-*size* proxy, not a calibrated
/// physical pressure or Force Touch reading.
public struct MIDIHelperSustainState: Sendable {
    private var trackpadHeld = false
    private var mouseWasTouching = false
    private var mouseLatched = false

    public private(set) var snapshot = MIDIHelperSustainSnapshot()

    public init() {}

    public mutating func update(
        trackpadContactSizes: [Double],
        magicMouseTouching: Bool,
        settings: MIDIHelperSustainSettings
    ) -> MIDIHelperSustainSnapshot {
        let threshold = max(0.05, min(1, settings.trackpadContactThreshold))
        let contactSize = trackpadContactSizes
            .filter { $0.isFinite }
            .map { min(1, max(0, $0)) }
            .max() ?? 0

        if settings.trackpadEnabled, !trackpadContactSizes.isEmpty {
            // Hysteresis prevents CC64 chattering near the threshold.
            let releaseThreshold = max(0, threshold - 0.08)
            trackpadHeld = trackpadHeld
                ? contactSize >= releaseThreshold
                : contactSize >= threshold
        } else {
            trackpadHeld = false
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
            }
        }

        mouseWasTouching = magicMouseTouching
        snapshot = MIDIHelperSustainSnapshot(
            trackpadActive: trackpadHeld,
            magicMouseActive: mouseActive
        )
        return snapshot
    }

    public mutating func reset() {
        trackpadHeld = false
        mouseWasTouching = false
        mouseLatched = false
        snapshot = MIDIHelperSustainSnapshot()
    }
}
