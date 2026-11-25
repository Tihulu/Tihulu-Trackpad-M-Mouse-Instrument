import Foundation

/// Input modes are explicit: a contact is not a Force Touch pressure reading.
/// Physical clicks are provided separately by the macOS event monitor.
public enum TrackpadSustainGesture: String, CaseIterable, Identifiable, Sendable, Codable {
    case contactThreshold = "Contact Threshold"
    case touchHold = "Touch Hold"
    case tapToggle = "Tap Toggle"
    case physicalClickHold = "Physical Click Hold"
    case physicalClickToggle = "Physical Click Toggle"

    public var id: String { rawValue }
}

/// Explicit sensor source for the Trackpad Contact Threshold sustain mode.
/// CoreGraphics click pressure is experimental and requires a physical click.
public enum TrackpadSustainSensor: String, CaseIterable, Identifiable, Sendable, Codable {
    case contactSize = "Contact Size"
    case clickPressure = "Click Pressure (Experimental)"

    public var id: String { rawValue }
}

public enum MagicMouseSustainGesture: String, CaseIterable, Identifiable, Sendable, Codable {
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
    public var trackpadSensor: TrackpadSustainSensor
    public var magicMouseEnabled: Bool
    public var magicMouseGesture: MagicMouseSustainGesture
    /// Zero preserves legacy any-contact tap behavior; a positive value requires a valid size at onset.
    public var magicMouseTapThreshold: Double

    public init(
        trackpadEnabled: Bool = false,
        trackpadContactThreshold: Double = 0.55,
        magicMouseEnabled: Bool = false,
        magicMouseGesture: MagicMouseSustainGesture = .touchHold,
        trackpadGesture: TrackpadSustainGesture = .contactThreshold,
        trackpadSensor: TrackpadSustainSensor = .contactSize,
        magicMouseTapThreshold: Double = 0
    ) {
        self.trackpadEnabled = trackpadEnabled
        self.trackpadContactThreshold = trackpadContactThreshold
        self.trackpadGesture = trackpadGesture
        self.trackpadSensor = trackpadSensor
        self.magicMouseEnabled = magicMouseEnabled
        self.magicMouseGesture = magicMouseGesture
        self.magicMouseTapThreshold = magicMouseTapThreshold
    }

    /// The user's pedal settings remain stored; only selected surfaces
    /// may participate in the current consumer's sustain ownership.
    public func restricted(trackpad:Bool,magicMouse:Bool) -> Self {
        var result = self
        result.trackpadEnabled = trackpadEnabled && trackpad
        result.magicMouseEnabled = magicMouseEnabled && magicMouse
        return result
    }

    public var needsPhysicalClicks: Bool {
        (trackpadEnabled &&
            (trackpadGesture == .physicalClickHold || trackpadGesture == .physicalClickToggle ||
             (trackpadGesture == .contactThreshold && trackpadSensor == .clickPressure))) ||
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

    public var hasEffects:Bool { vibrato || pitchBend || expression }
    public static var sustainOnly:Self { .init(vibrato:false,pitchBend:false,expression:false) }
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
    private var previousTrackpadGesture: TrackpadSustainGesture?
    private var previousTrackpadSensor: TrackpadSustainSensor?
    private var previousMouseGesture: MagicMouseSustainGesture?

    public private(set) var snapshot = MIDIHelperSustainSnapshot()

    public init() {}

    public mutating func update(
        trackpadContactSizes: [Double],
        magicMouseTouching: Bool,
        settings: MIDIHelperSustainSettings,
        trackpadClickDown: Bool = false,
        magicMouseClickDown: Bool = false,
        trackpadClickPressure: Double? = nil,
        magicMouseContactSizes: [Double] = [],
        freshContacts: Bool = true
    ) -> MIDIHelperSustainSnapshot {
        let threshold = settings.trackpadContactThreshold
        let validSizes = trackpadContactSizes.filter { $0.isFinite && (0...1).contains($0) }
        let contactSize = validSizes.max() ?? 0
        let trackpadTouching = !validSizes.isEmpty
        let trackpadModeChanged = previousTrackpadGesture != settings.trackpadGesture || previousTrackpadSensor != settings.trackpadSensor
        let mouseModeChanged = previousMouseGesture != settings.magicMouseGesture
        if trackpadModeChanged {
            trackpadHeld = false; trackpadLatched = false
        }
        if mouseModeChanged { mouseLatched = false }
        previousTrackpadGesture = settings.trackpadGesture
        previousTrackpadSensor = settings.trackpadSensor
        previousMouseGesture = settings.magicMouseGesture

        let trackpadActive: Bool
        if !settings.trackpadEnabled ||
            (settings.trackpadGesture == .contactThreshold &&
             (!threshold.isFinite || !(0.05...1).contains(threshold))) {
            // Invalid configuration must release even on a click-only
            // callback carrying no fresh contact sample.
            trackpadHeld = false
            trackpadLatched = false
            trackpadActive = false
        } else if !freshContacts && (
            settings.trackpadGesture == .touchHold || settings.trackpadGesture == .tapToggle ||
            (settings.trackpadGesture == .contactThreshold && settings.trackpadSensor == .contactSize)
        ) {
            // A physical mouse-button callback is not a multitouch sample.
            // Preserve the last admitted contact result, never synthesize a
            // lift or onset from missing, stale or reset contact caches.
            trackpadActive = !trackpadModeChanged && snapshot.trackpadActive
        } else {
            switch settings.trackpadGesture {
            case .contactThreshold:
                let sensorValue: Double?
                switch settings.trackpadSensor {
                case .contactSize:
                    sensorValue = trackpadTouching ? contactSize : nil
                case .clickPressure:
                    // CGEvent mouse-button pressure is not calibrated Force
                    // Touch force. Missing values do not fall back to size.
                    sensorValue = trackpadClickDown ? trackpadClickPressure : nil
                }
                if threshold.isFinite, (0.05...1).contains(threshold),
                   let value = sensorValue, value.isFinite, (0...1).contains(value) {
                    let normalized = value
                    let releaseThreshold = max(0, threshold - 0.08)
                    trackpadHeld = trackpadHeld
                        ? normalized >= releaseThreshold
                        : normalized >= threshold
                } else {
                    trackpadHeld = false
                }
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
        if !settings.magicMouseEnabled ||
            (settings.magicMouseGesture == .tapToggle &&
             (!settings.magicMouseTapThreshold.isFinite || !(0...1).contains(settings.magicMouseTapThreshold))) {
            // Never preserve an old toggle under an invalid sensitivity.
            mouseLatched = false
            mouseActive = false
        } else if !freshContacts && (settings.magicMouseGesture == .touchHold || settings.magicMouseGesture == .tapToggle) {
            mouseActive = !mouseModeChanged && snapshot.magicMouseActive
        } else {
            switch settings.magicMouseGesture {
            case .touchHold:
                mouseLatched = false
                mouseActive = magicMouseTouching
            case .tapToggle:
                // Only a new contact session can toggle. A rejected onset
                // cannot become a tap later through size changes while held.
                let threshold = settings.magicMouseTapThreshold
                let qualified = threshold == 0 || (
                    threshold.isFinite && (0...1).contains(threshold) &&
                    magicMouseContactSizes.contains { $0.isFinite && (0...1).contains($0) && $0 >= threshold }
                )
                if magicMouseTouching && !mouseWasTouching && qualified {
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

        if freshContacts {
            trackpadWasTouching = trackpadTouching
            mouseWasTouching = magicMouseTouching
        }
        trackpadWasClicking = trackpadClickDown
        mouseWasClicking = magicMouseClickDown
        snapshot = .init(trackpadActive: trackpadActive, magicMouseActive: mouseActive)
        return snapshot
    }

    /// A disabled event tap can miss a click-up. Clear click-derived
    /// latches without canceling independent touch-derived sustain.
    public mutating func invalidatePhysicalClicks(settings:MIDIHelperSustainSettings) {
        trackpadWasClicking = false
        mouseWasClicking = false
        if settings.trackpadGesture == .physicalClickHold ||
           settings.trackpadGesture == .physicalClickToggle ||
           (settings.trackpadGesture == .contactThreshold && settings.trackpadSensor == .clickPressure) {
            trackpadHeld = false
            trackpadLatched = false
            snapshot.trackpadActive = false
        }
        if settings.magicMouseGesture == .physicalClickHold || settings.magicMouseGesture == .physicalClickToggle {
            mouseLatched = false
            snapshot.magicMouseActive = false
        }
    }

    public mutating func reset() {
        trackpadHeld = false
        trackpadWasTouching = false
        trackpadWasClicking = false
        trackpadLatched = false
        mouseWasTouching = false
        mouseWasClicking = false
        mouseLatched = false
        previousTrackpadGesture = nil
        previousTrackpadSensor = nil
        previousMouseGesture = nil
        snapshot = .init()
    }
}

/// Per-consumer boundary for physical click ownership. Long holds remain
/// valid after admission, but cannot cross a new Start/routing epoch.
public struct PhysicalClickSessionFence:Sendable {
    private var startedAt:Double?
    public init() {}
    public mutating func begin(now:Double) {
        startedAt = now.isFinite && now >= 0 ? now : nil
    }
    public mutating func end() { startedAt = nil }
    public func permits(receipt:Double?,now:Double,selected:Bool) -> Bool {
        guard selected,let startedAt,let receipt,receipt.isFinite,now.isFinite else { return false }
        return receipt >= startedAt && now >= receipt
    }
}

/// Conservative attribution from the current shared snapshot, not from
/// independent consumer caches. The OS click itself has no device identity.
public enum PhysicalClickAttribution {
    public static func resolve<Surface:Hashable>(_ touching:Set<Surface>,
        snapshotRevision:UInt64?,currentRevision:UInt64?,receivedAt:Double?,now:Double,
        clickReceipt:Double? = nil,notBefore:Double? = nil) -> Surface? {
        guard let snapshotRevision, let currentRevision, snapshotRevision == currentRevision,
              let receivedAt, receivedAt.isFinite, receivedAt>=0,now.isFinite,now>=receivedAt,
              now-receivedAt < 0.35, touching.count == 1 else { return nil }
        if let notBefore {
            // An event-monitor invalidation retires all earlier contact
            // observations, including samples still queued for delivery.
            guard notBefore.isFinite,notBefore>=0,receivedAt>=notBefore,
                  let clickReceipt,clickReceipt>=notBefore else { return nil }
        }
        if let clickReceipt {
            // Never attribute an earlier click to a later surface snapshot.
            // Also reject clicks before the monotonic epoch or in the future.
            guard clickReceipt.isFinite,clickReceipt >= 0,receivedAt >= 0,
                  receivedAt <= clickReceipt,clickReceipt <= now else { return nil }
        }
        return touching.first
    }
}


/// Hardware-independent keyboard-helper safety policy. Pedal contacts do
/// not also drive expression or bend unless explicitly requested.
public enum HelperPerformancePolicy {
    public static func permitsEffects(isTrackpad:Bool,settings:MIDIHelperSustainSettings,sharePedalSurface:Bool) -> Bool {
        sharePedalSurface || !(isTrackpad ? settings.trackpadEnabled : settings.magicMouseEnabled)
    }
    public static func validContact(x:Double,y:Double,size:Double) -> Bool {
        [x,y,size].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    /// Shared, testable production planner. No disabled assignment produces
    /// a target, and keyboard-friendly bend does not send RPN by default.
    public static func controls(x:Double,y:Double,size:Double,assignments:MIDIHelperAssignments,
        channel:Int,bendRange:Int,vibratoCC:Int,expressionCC:Int,configureReceiverBendRange:Bool = false)
        -> [SensorDestination:LegacyContinuousOwners.Value]? {
        guard validContact(x:x,y:y,size:size),(0...15).contains(channel),
            HelperCCPolicy.permits(vibrato:assignments.vibrato,expression:assignments.expression,
                vibratoCC:vibratoCC,expressionCC:expressionCC) else { return nil }
        var result:[SensorDestination:LegacyContinuousOwners.Value] = [:]
        if assignments.pitchBend {
            let bend = Int((8192+(x-0.5)*2*8191).rounded())
            result[.init(.pitchBend,channel:channel)] = .init(bend,neutral:8192,
                bendRange:configureReceiverBendRange ? max(1,min(24,bendRange)) : nil)
        }
        if assignments.vibrato {
            result[.init(.controlChange,channel:channel,number:vibratoCC)] = gainValue(Int((y*127).rounded()),cc:vibratoCC)
        }
        if assignments.expression {
            result[.init(.controlChange,channel:channel,number:expressionCC)] = gainValue(Int((size*127).rounded()),cc:expressionCC)
        }
        return result
    }
    public static func gainValue(_ value:Int,cc:Int) -> LegacyContinuousOwners.Value {
        .init(value,neutral:neutral(forCC:cc),preserveOnRelease:[7,11].contains(cc))
    }
    public static func neutral(forCC cc:Int) -> Int { [7,11].contains(cc) ? 127 : 0 }
}

    
/// After a live routing change, old held contacts must not become new
/// pedal or expressive onsets. Only a genuinely idle selected surface
/// frame re-arms the new configuration.
public struct HelperRearmGate: Sendable {
    public private(set) var waiting = false
    public init() {}
    public mutating func invalidate() { waiting = true }
    public mutating func reset() { waiting = false }
    public mutating func permits(touching:Bool,clicking:Bool,freshFrame:Bool = true) -> Bool {
        guard waiting else { return true }
        if freshFrame && !touching && !clicking { waiting = false }
        return false
    }
}
