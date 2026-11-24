#if os(macOS)
import AppKit
import NoSpeakerCore

/// Native NSTouchBar surface. Configured at the application responder level so
/// it remains accessible while the user switches between Studio modes.
/// On Macs with no physical Touch Bar the same controls are available in the
/// Touch Bar & Tilt page as a working on-screen fallback.
@MainActor
final class StudioTouchBarBridge: NSObject, NSTouchBarDelegate {
    weak var controller: StudioController?
    private var profile = TouchBarProfile()
    private weak var chordControl: NSSegmentedControl?
    private let prefix = "com.tihulu.instrument.touchbar."

    func install(profile: TouchBarProfile) {
        self.profile = profile.normalized()
        chordControl = nil
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(prefix + "layout")
        bar.defaultItemIdentifiers = self.profile.zones.map(identifier)
        bar.customizationAllowedItemIdentifiers = TouchBarZone.allCases.map(identifier)
        NSApplication.shared.touchBar = bar
        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true
    }

    private func identifier(_ zone: TouchBarZone) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(prefix + zone.rawValue)
    }

    private func zone(for identifier: NSTouchBarItem.Identifier) -> TouchBarZone? {
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        let raw = String(identifier.rawValue.dropFirst(prefix.count))
        return TouchBarZone(rawValue: raw)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard let zone = zone(for: identifier) else { return nil }
        switch zone {
        case .keys:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Fretted Piano"
            let labels = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G"]
            let piano = NSSegmentedControl(
                labels: labels,
                trackingMode: .momentary,
                target: self,
                action: #selector(pianoKeyPressed(_:))
            )
            piano.segmentStyle = .rounded
            item.view = piano
            return item
        case .chords:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Chord Pads (arm in Studio)"
            let pads = NSSegmentedControl(
                labels: chordLabels(), trackingMode: .momentary,
                target: self, action: #selector(chordPadPressed(_:))
            )
            pads.segmentStyle = .rounded
            pads.isEnabled = controller?.chordArmed == true
            chordControl = pads
            item.view = pads
            return item
        case .sustain:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Sustain"
            if profile.sustainMode == .hold {
                let button = HoldSustainButton(title: "Sustain Hold", target: nil, action: nil)
                button.onPress = { [weak self] pressed in
                    self?.controller?.touchBarSustainPressed(pressed)
                }
                item.view = button
            } else {
                item.view = NSButton(
                    title: "Sustain Toggle",
                    target: self,
                    action: #selector(sustainToggled(_:))
                )
            }
            return item
        case .fretless:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Fretless Piano"
            let slider = FretlessTouchSlider(
                value: 0.5, minValue: 0, maxValue: 1,
                target: self, action: #selector(sliderChanged(_:))
            )
            slider.tag = 2
            slider.isContinuous = true
            slider.onPress = { [weak self, weak slider] pressed in
                guard let self else { return }
                let note = self.profile.baseNote
                self.controller?.touchBarKey(note, pressed: pressed)
                if !pressed {
                    // Neutralize pitch bend and let go of the note on release.
                    self.controller?.touchBarValue(.fretless, normalized: 0.5)
                    slider?.doubleValue = 0.5
                }
            }
            item.view = slider
            return item
        case .pitchBend, .vibrato, .expression, .filter:
            let item = NSSliderTouchBarItem(identifier: identifier)
            item.customizationLabel = zone.rawValue
            item.label = zone.rawValue
            item.slider.minValue = 0
            item.slider.maxValue = 1
            item.slider.doubleValue = zone == .pitchBend || zone == .fretless ? 0.5 : 0
            item.slider.isContinuous = true
            item.slider.target = self
            item.slider.action = #selector(sliderChanged(_:))
            item.slider.tag = switch zone {
            case .pitchBend: 1
            case .fretless: 2
            case .vibrato: 3
            case .expression: 4
            case .filter: 5
            default: 0
            }
            return item
        }
    }

    private func chordLabels() -> [String] {
        (0..<ChordBank.padCount).map { slot in
            String((controller?.chordBank.pad(at: slot)?.name ?? "Pad " + String(slot + 1)).prefix(8))
        }
    }

    func refreshChordControls() {
        guard let control = chordControl else { return }
        for (index, title) in chordLabels().enumerated() {
            control.setLabel(title, forSegment: index)
        }
        control.isEnabled = controller?.chordArmed == true
    }

    @objc private func chordPadPressed(_ sender: NSSegmentedControl) {
        let slot = sender.selectedSegment
        guard (0..<ChordBank.padCount).contains(slot) else { return }
        controller?.triggerChordPad(slot)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let zone: TouchBarZone
        switch sender.tag {
        case 1: zone = .pitchBend
        case 2: zone = .fretless
        case 3: zone = .vibrato
        case 4: zone = .expression
        case 5: zone = .filter
        default: return
        }
        controller?.touchBarValue(zone, normalized: sender.doubleValue)
    }

    @objc private func pianoKeyPressed(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        let note = profile.baseNote + sender.selectedSegment
        controller?.touchBarKey(note, pressed: true)
        // Native segmented controls deliver tap actions rather than per-finger
        // release callbacks. Give each key a brief, bounded note duration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.controller?.touchBarKey(note, pressed: false)
        }
    }

    @objc private func sustainToggled(_ sender: NSButton) {
        controller?.touchBarSustainPressed(true)
        sender.title = controller?.touchBarSustainOn == true ? "Sustain ON" : "Sustain Toggle"
    }
}

@MainActor
private final class FretlessTouchSlider: NSSlider {
    var onPress: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        super.mouseDown(with: event)
        onPress?(false)
    }
}

@MainActor
private final class HoldSustainButton: NSButton {
    var onPress: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        super.mouseDown(with: event)
        onPress?(false)
    }
}
#endif
