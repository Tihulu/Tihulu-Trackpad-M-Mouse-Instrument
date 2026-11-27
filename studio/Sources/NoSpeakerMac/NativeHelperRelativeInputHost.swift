#if os(macOS)
import Foundation
import NoSpeakerCore

/// Serialized native binding for one explicitly selected Helper surface.
/// Controller must retain a single host, poll its watchdog, and close it
/// before changing configuration, monitor, MIDI service or source identity.
@MainActor
public final class NativeHelperRelativeInputHost {
    private var binding: NativeHelperRelativeInputBinding
    private let midi: MIDIHapticService
    private let surface: TouchSurfaceKind
    private let registration: UUID

    public init?(boundary: NativeHelperRelativeArmBoundary, monitor: UUID,
                 configuration: NativeHelperRelativeSingleChannel, orientation: SurfaceOrientation,
                 midi: MIDIHapticService) {
        guard let binding = NativeHelperRelativeInputBinding(boundary: boundary, monitor: monitor,
            configuration: configuration, orientation: orientation) else { return nil }
        self.binding = binding; self.midi = midi
        self.surface = boundary.source == .trackpad ? .trackpad : .magicMouse
        self.registration = boundary.registration
    }

    public func receive(_ sample: QueuedTouchSnapshot, monitor: UUID,
                        live: @escaping () -> Bool) -> NativeHelperRelativeInputBinding.Result {
        let midi = self.midi, required = [surface: registration]
        let source: NativeHelperRelativeClutch.Surface = sample.sourceSurface == .trackpad ? .trackpad : .magicMouse
        return binding.receive(sample.relativeFrame, source: source, monitor: monitor,
            sequence: sample.stamp.sequence, clock: { Int64(clamping: DispatchTime.now().uptimeNanoseconds) },
            live: { live() && HapticTrackpadDriver.matchesTouchRegistrations(required) },
            activeLeaseValid: { midi.hasActiveRelativeHelperLease },
            begin: { plan, permits in midi.beginRelativeHelperOutput(plan: plan, admitOnset: permits) },
            move: { values, permits in midi.applyRelativeHelperMovement(values, admitOnset: permits) },
            retire: { neutral, plan in midi.retireRelativeHelperOutput(genuineNeutral: neutral, initialPlan: plan) })
    }

    public func poll(live: () -> Bool) -> NativeHelperRelativeInputBinding.Result {
        let midi = self.midi
        let admitted = live() && HapticTrackpadDriver.matchesTouchRegistrations([surface: registration])
        return binding.poll(nowNS: Int64(clamping: DispatchTime.now().uptimeNanoseconds), live: admitted,
            activeLeaseValid: { midi.hasActiveRelativeHelperLease },
            retire: { neutral, plan in midi.retireRelativeHelperOutput(genuineNeutral: neutral, initialPlan: plan) })
    }

    @discardableResult
    public func close() -> NativeHelperRelativeInputBinding.Result {
        let midi = self.midi
        return binding.close(retire: { neutral, plan in
            midi.retireRelativeHelperOutput(genuineNeutral: neutral, initialPlan: plan) })
    }
}
#endif
