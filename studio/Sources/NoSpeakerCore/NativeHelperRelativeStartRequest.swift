/// Declarative preflight for the first manual Relative Helper mode only.
/// A successful result is not a running session or permission to send MIDI.
/// The host must independently validate device identity, freshness, ownership,
/// cleanup and transport, and close/rearm on configuration changes.
public struct NativeHelperRelativeStartRequest: Sendable {
    public typealias Axis = NativeHelperRelativeClutch.Axis
    public typealias Surface = NativeHelperRelativeClutch.Surface

    public enum Failure: String, Error, Equatable, Sendable {
        case singleSurfaceRequired, midiOutputRequired, expressiveAxisRequired
        case pedalSharingRequired, automaticBendRangeUnsupported
        case channelOutOfRange, invalidManualSettings, invalidExpressiveTargets
    }

    public let surface: Surface
    public let orientation: SurfaceOrientation
    public let output: NativeHelperRelativeSingleChannel

    /// nil selection represents a non-single-surface choice (e.g. Both).
    /// selectedSurfaceUsesSustain is the effective pedal assignment, not
    /// the current pedal contact level. This never changes a pedal setting.
    /// Channels are one-based at the UI boundary, validated before subtraction.
    public static func resolve(selectedSurface: Surface?, orientation: SurfaceOrientation,
        sendToDAW: Bool, enabled: Set<Axis>, selectedSurfaceUsesSustain: Bool,
        sharePedalSurface: Bool, configureReceiverBendRange: Bool,
        oneBasedChannel: Int, vibratoCC: Int, expressionCC: Int,
        settings: NativeHelperRelativeManualSettings) -> Result<Self, Failure> {
        guard let surface = selectedSurface else { return .failure(.singleSurfaceRequired) }
        guard sendToDAW else { return .failure(.midiOutputRequired) }
        guard !enabled.isEmpty else { return .failure(.expressiveAxisRequired) }
        guard !selectedSurfaceUsesSustain || sharePedalSurface else { return .failure(.pedalSharingRequired) }
        guard !enabled.contains(.x) || !configureReceiverBendRange else { return .failure(.automaticBendRangeUnsupported) }
        guard (1...16).contains(oneBasedChannel) else { return .failure(.channelOutOfRange) }
        guard settings.isValid else { return .failure(.invalidManualSettings) }
        guard let output = NativeHelperRelativeSingleChannel(settings: settings, enabled: enabled,
            channel: oneBasedChannel - 1, vibratoCC: vibratoCC, expressionCC: expressionCC) else {
            return .failure(.invalidExpressiveTargets)
        }
        return .success(.init(surface: surface, orientation: orientation, output: output))
    }
}
