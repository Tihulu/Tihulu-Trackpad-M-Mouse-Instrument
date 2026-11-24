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
    private var profileEpoch = TouchBarGestureEpoch()
    private let profileControls = NSHashTable<NSControl>.weakObjects()
    private weak var installedBar: NSTouchBar?
    private weak var attachedWindow: NSWindow?
    private weak var chordControl: NSSegmentedControl?
    private let prefix = "com.tihulu.instrument.touchbar."

    private var builderToken: UUID?
    private var builderID: NSTouchBarItem.Identifier { .init(prefix + "builderRibbon") }

    func install(profile: TouchBarProfile, builderToken: UUID? = nil, force: Bool = false) {
        self.builderToken = builderToken
        let normalized = profile.normalized()
        if force || normalized != self.profile {
            profileEpoch.invalidate()
            profileControls.removeAllObjects()
        }
        self.profile = normalized
        chordControl = nil
        // Detach only our own old bar before installing a replacement.
        if let oldBar = installedBar, let oldWindow = attachedWindow, oldWindow.touchBar === oldBar {
            oldWindow.touchBar = nil
        }
        attachedWindow = nil
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier(prefix + "layout")
        bar.defaultItemIdentifiers = self.profile.zones.map(identifier)
        bar.customizationAllowedItemIdentifiers = TouchBarZone.allCases.map(identifier)
        if builderToken != nil {
            bar.defaultItemIdentifiers.append(builderID)
            bar.customizationAllowedItemIdentifiers.append(builderID)
        }
        installedBar = bar
        NSApplication.shared.touchBar = bar
        attachToKeyWindow()
        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true
    }

    /// Window-level responder routing supplements the application fallback.
    func attachToKeyWindow() {
        guard let bar = installedBar, let window = NSApplication.shared.mainWindow,
              window.isVisible, !window.isSheet else { return }
        if let old = attachedWindow, old !== window, old.touchBar === bar { old.touchBar = nil }
        window.touchBar = bar
        attachedWindow = window
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
        guard touchBar === installedBar else { return nil }
        controller?.recordNativeTouchBarItemRequest()
        let profileStamp = profileEpoch.revision
        if identifier == builderID, let token = builderToken {
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Builder ribbon"
            let slider = BuilderRibbonSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.onValue = { [weak self] value in
                guard let self, self.profileEpoch.accepts(profileStamp) else { return }
                self.controller?.recordNativeTouchBarInput()
                self.controller?.builderBarValue(value, token: token)
            }
            slider.setAccessibilityLabel("Builder ribbon")
            item.view = slider
            return item
        }
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
            profileControls.add(piano)
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
            profileControls.add(pads)
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
                var gesture: UInt64?
                button.onPress = { [weak self] pressed in
                    guard let self, self.profileEpoch.accepts(profileStamp), let controller = self.controller else { return }
                    if pressed {
                        controller.recordNativeTouchBarInput()
                        guard gesture == nil else { return }
                        gesture = controller.touchBarGestureEpoch.revision
                        controller.touchBarSustainPressed(true)
                    } else if let captured = gesture {
                        gesture = nil
                        if controller.touchBarGestureEpoch.accepts(captured) { controller.touchBarSustainPressed(false) }
                    }
                }
                item.view = button
            } else {
                let button = NSButton(title: "Sustain Toggle", target: self, action: #selector(sustainToggled(_:)))
                profileControls.add(button)
                item.view = button
            }
            return item
        case .fretless:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Fretless Piano"
            let slider = PerformanceTouchSlider(
                value: 0.5, minValue: 0, maxValue: 1,
                target: self, action: #selector(sliderChanged(_:))
            )
            slider.tag = 2
            slider.isContinuous = true
            profileControls.add(slider)
            slider.onPress = { [weak self, weak slider] pressed in
                guard let self, let slider, self.profileEpoch.accepts(profileStamp), let controller = self.controller else { return }
                let note = self.profile.baseNote
                if pressed {
                    guard slider.gesture == nil else { return }
                    slider.gesture = controller.touchBarGestureEpoch.revision
                    controller.touchBarKey(note, pressed: true, owner: .nativeRibbon)
                } else if let captured = slider.gesture {
                    slider.gesture = nil
                    slider.doubleValue = 0.5
                    guard controller.touchBarGestureEpoch.accepts(captured) else { return }
                    controller.touchBarKey(note, pressed: false, owner: .nativeRibbon)
                    controller.touchBarValue(.fretless, normalized: 0.5, releaseOnly: true)
                }
            }
            item.view = slider
            return item
        case .pitchBend, .vibrato, .expression, .filter:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = zone.rawValue
            let slider = PerformanceTouchSlider(
                value: zone == .pitchBend ? 0.5 : 0, minValue: 0, maxValue: 1,
                target: self, action: #selector(sliderChanged(_:))
            )
            slider.isContinuous = true
            slider.setAccessibilityLabel(zone.rawValue)
            profileControls.add(slider)
            slider.onPress = { [weak self, weak slider] pressed in
                guard let slider else { return }
                if !pressed { slider.gesture = nil; return }
                guard let self, self.profileEpoch.accepts(profileStamp), let controller = self.controller else { return }
                slider.gesture = controller.touchBarGestureEpoch.revision
            }
            slider.tag = switch zone {
            case .pitchBend: 1
            case .fretless: 2
            case .vibrato: 3
            case .expression: 4
            case .filter: 5
            default: 0
            }
            // Preserve the control label and continuous/latched behavior.
            let label = NSTextField(labelWithString: zone.rawValue)
            let controls = NSStackView(views: [label, slider])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 4
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            item.view = controls
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
        guard profileControls.contains(sender) else { return }
        let slot = sender.selectedSegment
        guard (0..<ChordBank.padCount).contains(slot) else { return }
        controller?.recordNativeTouchBarInput()
        controller?.triggerChordPad(slot)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard profileControls.contains(sender) else { return }
        guard let controller else { return }
        if let slider = sender as? PerformanceTouchSlider,
           !controller.touchBarGestureEpoch.permitsSample(captured: slider.gesture) { return }
        let zone: TouchBarZone
        switch sender.tag {
        case 1: zone = .pitchBend
        case 2: zone = .fretless
        case 3: zone = .vibrato
        case 4: zone = .expression
        case 5: zone = .filter
        default: return
        }
        controller.recordNativeTouchBarInput()
        controller.touchBarValue(zone, normalized: sender.doubleValue)
    }

    @objc private func pianoKeyPressed(_ sender: NSSegmentedControl) {
        guard profileControls.contains(sender), sender.selectedSegment >= 0 else { return }
        let note = profile.baseNote + sender.selectedSegment
        // Controller owns the bounded tap and invalidates delayed releases on stop.
        controller?.recordNativeTouchBarInput()
        controller?.touchBarNativeTap(note)
    }

    @objc private func sustainToggled(_ sender: NSButton) {
        guard profileControls.contains(sender) else { return }
        controller?.recordNativeTouchBarInput()
        controller?.touchBarSustainPressed(true)
        sender.title = controller?.touchBarSustainOn == true ? "Sustain ON" : "Sustain Toggle"
    }
}

@MainActor
private final class BuilderRibbonSlider: NSSlider {
    var onValue: ((Double?) -> Void)?
    override func mouseDown(with event: NSEvent) {
        target = self
        action = #selector(changed(_:))
        isContinuous = true
        defer { onValue?(nil) }
        super.mouseDown(with: event)
    }
    @objc private func changed(_ sender: NSSlider) { onValue?(sender.doubleValue) }
}

@MainActor
private final class PerformanceTouchSlider: NSSlider {
    var gesture: UInt64?
    var onPress: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        defer { onPress?(false) }
        super.mouseDown(with: event)
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
