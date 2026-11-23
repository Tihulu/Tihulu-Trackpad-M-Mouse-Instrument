#if os(macOS)
import Foundation
import SwiftUI
import NoSpeakerCore
import NoSpeakerMac

struct ActiveMIDINote: Identifiable, Equatable {
    var id: String { "\(channel)-\(note)" }
    var channel: Int
    var note: Int
    var velocity: Int
}

@MainActor
final class StudioController: ObservableObject {
    @Published var engineStatus = "Initializing haptic engine…"
    @Published var engineReady = false
    @Published var lastError: String?
    @Published var isPlaying = false
    @Published var masterLevel = 0.75
    @Published var bpm = 120.0
    @Published var midiRunning = false
    @Published var touchRunning = false
    @Published var touchPreviewRunning = false
    @Published var touchContact = TrackpadContact()
    @Published var touchStates: [TouchPerformanceState] = []
    @Published var midiHelperStates: [TouchPerformanceState] = []
    @Published var midiHelperRunning = false
    @Published var midiHelperSustainActive = false
    @Published var midiHelperTrackpadSustainActive = false
    @Published var midiHelperMagicMouseSustainActive = false
    @Published var touchInstrumentSustainActive = false
    @Published var inputControlsArmed = false
    @Published var mouseCaptureActive = false
    @Published var captureHotkey: CaptureHotkey = .f8
    @Published var inputControlsStatus = "Off · mouse controls the desktop normally"
    @Published var activeMIDINotes: [ActiveMIDINote] = []
    @Published var systemAudioRunning = false
    @Published var lastMIDIMessage = "No MIDI received yet"
    @Published var currentFileName = "No file loaded"
    @Published var activeProfile: AudioHapticProfile = .fullMix

    private var driver: HapticTrackpadDriver?
    private var playback: HapticPlaybackEngine?
    private var touch: TouchInstrumentService?
    private var midi: MIDIHapticService?
    private var systemAudio: SystemAudioHapticCapture?
    private var currentTouchConfiguration = TouchInstrumentConfiguration()
    private var touchMIDIOutEnabled = false
    private var touchMIDIMode: TouchMIDIMode = .standard
    private var touchMultiTouchEnabled = true
    private var touchMIDIChannel = 0

    private var helperControls = MIDIHelperControlSelection()
    private var helperSendToDAW = true
    private var helperTargetChannel = 0
    private var helperPitchBendRange = 12
    private var helperVibratoCC = 1
    private var helperExpressionCC = 11
    private var helperLocalSound = false
    private var helperSurfaceSelection: TouchSurfaceSelection = .trackpad
    private var helperSustainSettings = MIDIHelperSustainSettings()
    private var helperSustainState = MIDIHelperSustainState()
    private var touchSustainState = MIDIHelperSustainState()
    private var inputCapture: ExpressiveInputCapture?
    private var physicalTrackpadDown = false
    private var physicalMouseDown = false
    private var lastClickSurface: TouchSurfaceKind?
    private var activeMIDINoteMap: [String: ActiveMIDINote] = [:]

    init() {
        prepareEngine()
    }

    func prepareEngine() {
        do {
            let driver = try HapticTrackpadDriver()
            try driver.open()
            self.driver = driver
            self.playback = HapticPlaybackEngine(driver: driver)
            self.touch = TouchInstrumentService(driver: driver)
            self.midi = MIDIHapticService(driver: driver)
            self.systemAudio = SystemAudioHapticCapture(driver: driver)
            engineReady = true
            engineStatus = driver.isBuiltIn ? "Built-in Force Touch trackpad ready" : "External Force Touch trackpad ready"
            lastError = nil
        } catch {
            engineReady = false
            engineStatus = "Haptic engine unavailable"
            lastError = error.localizedDescription
        }
    }

    func panicStop() {
        inputCapture?.stop()
        inputControlsArmed = false
        mouseCaptureActive = false
        inputControlsStatus = "Panic Stop · pointer returned to desktop"
        playback?.stop(closeDriver: true)
        touch?.stopPreview()
        midi?.stop()
        Task { await systemAudio?.stop() }
        isPlaying = false
        touchRunning = false
        touchPreviewRunning = false
        midiHelperRunning = false
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        physicalTrackpadDown = false
        physicalMouseDown = false
        lastClickSurface = nil
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        touchContact = TrackpadContact()
        touchStates = []
        midiHelperStates = []
        activeMIDINotes = []
        activeMIDINoteMap.removeAll()
        midiRunning = false
        systemAudioRunning = false
        engineReady = false
        engineStatus = "Stopped — press Reconnect to reopen the trackpad"
    }

    func reconnect() {
        driver?.close()
        driver = nil
        prepareEngine()
    }

    func speak(_ text: String, voice: String?) {
        guard requireEngine(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPlaying = true
        let renderText = text
        let renderVoice = voice
        Task {
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try VoiceHapticService.render(text: renderText, voice: renderVoice)
                }.value
                playback?.play(events: events, masterLevel: masterLevel)
                isPlaying = false
            } catch {
                fail(error)
            }
        }
    }

    func playNotes(_ steps: [NoteStep], length: Int = 16, loop: Bool = false) {
        guard requireEngine() else { return }
        do {
            let events = try HapticPatternRenderer.notes(.init(bpm: bpm, stepsPerBeat: 4, length: length, steps: steps))
            playback?.play(events: events, masterLevel: masterLevel, loop: loop)
            isPlaying = true
        } catch { fail(error) }
    }

    func playDrums(_ hits: [DrumStep], length: Int = 16, loop: Bool = false) {
        guard requireEngine() else { return }
        let events = HapticPatternRenderer.drums(.init(bpm: bpm, stepsPerBeat: 4, length: length, hits: hits))
        playback?.play(events: events, masterLevel: masterLevel, loop: loop)
        isPlaying = true
    }

    func stopPlayback() {
        playback?.stop(closeDriver: false)
        isPlaying = false
    }

    func testTone(frequency: Double) {
        guard requireEngine() else { return }
        let duration = max(2, (0.04 * frequency).rounded()) / frequency * 1_000
        playback?.play(frame: .init(tones: [.init(frequencyHz: frequency)], durationMS: duration, level: masterLevel))
    }

    func sweep() {
        guard requireEngine() else { return }
        var events: [ScheduledHapticEvent] = []
        let duration = 5.0
        let step = 0.012
        var time = 0.0
        while time < duration {
            let frequency = 100 * pow(40, time / duration)
            events.append(.init(time: time, frame: .init(
                tones: [.init(frequencyHz: frequency)], durationMS: step * 1_000, level: masterLevel
            )))
            time += step
        }
        playback?.play(events: events, masterLevel: 1)
        isPlaying = true
    }

    func startTouchPreview(configuration: TouchInstrumentConfiguration) {
        guard requireEngine(), let touch else { return }
        currentTouchConfiguration = configuration

        if touchPreviewRunning {
            touch.update(configuration: configuration)
            return
        }

        do {
            try touch.startPreview(configuration: configuration) { [weak self] states in
                Task { @MainActor in
                    self?.handleTouchStates(states)
                }
            }
            touchPreviewRunning = true
            engineStatus = "Touch preview active · no MIDI or haptic output until Start"
        } catch {
            fail(error)
        }
    }

    func updateTouchConfiguration(_ configuration: TouchInstrumentConfiguration) {
        currentTouchConfiguration = configuration
        touch?.update(configuration: configuration)
    }

    func stopTouchPreview() {
        touch?.stopPreview()
        midi?.releaseTouchSustain()
        midi?.endAllTouchOutput()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touchPreviewRunning = false
        touchRunning = false
        touchMIDIOutEnabled = false
        touchStates = []
        touchContact = TrackpadContact()
        engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
    }

    func startTouch(
        configuration: TouchInstrumentConfiguration,
        midiOut: Bool,
        midiMode: TouchMIDIMode = .standard,
        multiTouch: Bool = true,
        midiChannel: Int = 0
    ) {
        guard requireEngine(), let touch else { return }
        currentTouchConfiguration = configuration
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touchMIDIOutEnabled = midiOut
        touchMIDIMode = midiMode
        touchMultiTouchEnabled = multiTouch
        touchMIDIChannel = max(0, min(15, midiChannel))

        if !touchPreviewRunning {
            startTouchPreview(configuration: configuration)
        } else {
            touch.update(configuration: configuration)
        }

        if midiOut, !midiRunning {
            startMIDI()
        }

        touch.setActive(true)
        touchRunning = true
        engineStatus = midiOut
            ? (configuration.fretless
               ? "Touch Instrument active · Fretless \(midiMode.rawValue) Out"
               : "Touch Instrument active · \(midiMode.rawValue) Out")
            : (configuration.fretless
               ? "Touch Instrument active · Fretless"
               : "Touch Instrument active")
    }

    func startTouch(rootMIDI: Int, scale: TouchScale, fretless: Bool = false, midiOut: Bool = false) {
        startTouch(
            configuration: .init(
                baseMIDINote: rootMIDI,
                scale: scale,
                fretless: fretless,
                masterLevel: masterLevel
            ),
            midiOut: midiOut
        )
    }

    func stopTouch() {
        touch?.setActive(false)
        midi?.releaseTouchSustain()
        midi?.endAllTouchOutput()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touchRunning = false
        touchMIDIOutEnabled = false
        engineStatus = touchPreviewRunning
            ? "Touch preview active · no MIDI or haptic output until Start"
            : (engineReady ? "Force Touch trackpad ready" : engineStatus)
    }

    private func handleTouchStates(_ states: [TouchPerformanceState]) {
        touchStates = states
        if let firstTrackpad = states.first(where: { $0.surface == .trackpad && $0.isTouching }) {
            touchContact = TrackpadContact(
                id: firstTrackpad.contactID,
                isDown: firstTrackpad.isTouching,
                x: Float(firstTrackpad.x),
                y: Float(firstTrackpad.y),
                size: Float(firstTrackpad.pressure)
            )
        } else {
            touchContact = TrackpadContact()
        }

        guard touchRunning, touchMIDIOutEnabled else { return }
        updateTouchInstrumentSustain(states)
        midi?.sendTouchStates(
            states,
            configuration: currentTouchConfiguration,
            midiMode: touchMIDIMode,
            baseChannel: touchMIDIChannel,
            multiTouchEnabled: touchMultiTouchEnabled
        )
    }

    func startMIDI() {
        guard requireEngine(), let midi else { return }
        do {
            try midi.start(masterLevel: masterLevel) { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastMIDIMessage = "Ch \(message.channel + 1) · Note \(message.note) · Velocity \(message.velocity) · \(message.isNoteOn ? "On" : "Off")"
                    let key = "\(message.channel)-\(message.note)"
                    if message.isNoteOn {
                        self.activeMIDINoteMap[key] = .init(
                            channel: message.channel,
                            note: message.note,
                            velocity: message.velocity
                        )
                    } else {
                        self.activeMIDINoteMap.removeValue(forKey: key)
                    }
                    self.activeMIDINotes = self.activeMIDINoteMap.values.sorted {
                        if $0.channel == $1.channel { return $0.note < $1.note }
                        return $0.channel < $1.channel
                    }
                }
            }
            midiRunning = true
            engineStatus = "MIDI bridge active · Haptic MIDI In + Touch MIDI Out"
        } catch { fail(error) }
    }

    func stopMIDI() {
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        midi?.releaseHelperSustain()
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        midiHelperRunning = false
        midi?.endAllTouchOutput()
        midi?.resetHelperGesture(
            controls: helperControls,
            channel: helperTargetChannel,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
        midi?.stop()
        midiRunning = false
        activeMIDINoteMap.removeAll()
        activeMIDINotes = []
        engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
    }

    func startMIDIHelperPreview(surfaceSelection: TouchSurfaceSelection) {
        guard requireEngine(), let touch else { return }
        helperSurfaceSelection = surfaceSelection

        let config = TouchInstrumentConfiguration(
            surfaceSelection: surfaceSelection,
            velocityFromPressure: false,
            fixedVelocity: 100,
            pressureToExpression: true,
            localHapticSound: false,
            masterLevel: masterLevel
        )

        touch.stopPreview()
        touchPreviewRunning = false
        touchStates = []

        do {
            try touch.startPreview(configuration: config) { [weak self] states in
                Task { @MainActor in
                    self?.handleMIDIHelperStates(states)
                }
            }
            touchPreviewRunning = true
            engineStatus = "MIDI Helper preview active"
        } catch {
            fail(error)
        }
    }

    func updateMIDIHelperSurface(_ surfaceSelection: TouchSurfaceSelection) {
        helperSurfaceSelection = surfaceSelection
        let config = TouchInstrumentConfiguration(
            surfaceSelection: surfaceSelection,
            velocityFromPressure: false,
            fixedVelocity: 100,
            pressureToExpression: true,
            localHapticSound: false,
            masterLevel: masterLevel
        )
        touch?.update(configuration: config)
    }

    func startMIDIHelper(
        controls: MIDIHelperControlSelection,
        surfaceSelection: TouchSurfaceSelection,
        sendToDAW: Bool,
        localSound: Bool,
        targetChannel: Int,
        pitchBendRange: Int,
        vibratoCC: Int = 1,
        expressionCC: Int = 11,
        trackpadSustainEnabled: Bool = false,
        trackpadSustainThreshold: Double = 0.55,
        magicMouseSustainEnabled: Bool = false,
        magicMouseSustainGesture: MagicMouseSustainGesture = .touchHold,
        trackpadSustainGesture: TrackpadSustainGesture = .contactThreshold
    ) {
        let newSustainSettings = MIDIHelperSustainSettings(
            trackpadEnabled: controls.sustain && trackpadSustainEnabled,
            trackpadContactThreshold: trackpadSustainThreshold,
            trackpadGesture: trackpadSustainGesture,
            magicMouseEnabled: controls.sustain && magicMouseSustainEnabled,
            magicMouseGesture: magicMouseSustainGesture
        )
        let newChannel = max(0, min(15, targetChannel))
        if midiHelperRunning &&
            (newSustainSettings != helperSustainSettings ||
             newChannel != helperTargetChannel ||
             sendToDAW != helperSendToDAW ||
             surfaceSelection != helperSurfaceSelection ||
             controls != helperControls) {
            midi?.resetHelperGesture(
                controls: helperControls,
                channel: helperTargetChannel,
                vibratoCC: helperVibratoCC,
                expressionCC: helperExpressionCC
            )
            // Changing surface, channel or sustain mapping safely clears an
            // existing CC64 latch before the new routing becomes active.
            midi?.releaseHelperSustain()
            helperSustainState.reset()
            midiHelperSustainActive = false
            midiHelperTrackpadSustainActive = false
            midiHelperMagicMouseSustainActive = false
        }

        helperSustainSettings = newSustainSettings
        helperControls = controls
        helperSurfaceSelection = surfaceSelection
        helperSendToDAW = sendToDAW
        helperLocalSound = localSound
        helperTargetChannel = max(0, min(15, targetChannel))
        helperPitchBendRange = max(1, min(24, pitchBendRange))
        helperVibratoCC = max(0, min(127, vibratoCC))
        helperExpressionCC = max(0, min(127, expressionCC))

        if !touchPreviewRunning {
            startMIDIHelperPreview(surfaceSelection: surfaceSelection)
        } else {
            updateMIDIHelperSurface(surfaceSelection)
        }

        if !midiRunning {
            startMIDI()
        }
        midi?.setInputHapticsEnabled(localSound)
        midiHelperRunning = true
        engineStatus = "MIDI Helper active · configurable controls"
    }

    func stopMIDIHelper() {
        midi?.releaseHelperSustain()
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        midi?.resetHelperGesture(
            controls: helperControls,
            channel: helperTargetChannel,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
        midi?.setInputHapticsEnabled(true)
        midiHelperRunning = false
        engineStatus = touchPreviewRunning ? "MIDI Helper preview active" : "MIDI bridge active"
    }

    func stopMIDIHelperPreview() {
        if midiHelperRunning {
            stopMIDIHelper()
        }
        touch?.stopPreview()
        touchPreviewRunning = false
        midiHelperStates = []
    }

    private func handleMIDIHelperStates(_ states: [TouchPerformanceState]) {
        midiHelperStates = states
        guard midiHelperRunning else { return }

        let active = states.filter(\.isTouching)
        let snapshot = helperSustainState.update(
            trackpadContactSizes: active
                .filter { $0.surface == .trackpad }
                .map(\.pressure),
            magicMouseTouching: active.contains { $0.surface == .magicMouse },
            settings: helperSustainSettings,
            trackpadClickDown: physicalTrackpadDown,
            magicMouseClickDown: physicalMouseDown
        )
        midiHelperTrackpadSustainActive = snapshot.trackpadActive
        midiHelperMagicMouseSustainActive = snapshot.magicMouseActive
        midiHelperSustainActive = snapshot.isActive && helperSendToDAW && helperControls.sustain

        guard helperSendToDAW else {
            midi?.releaseHelperSustain()
            return
        }
        midi?.setHelperSustain(snapshot.isActive && helperControls.sustain, channel: helperTargetChannel)

        guard !active.isEmpty else {
            midi?.resetHelperGesture(
                controls: helperControls,
                channel: helperTargetChannel,
                vibratoCC: helperVibratoCC,
                expressionCC: helperExpressionCC
            )
            return
        }

        // Multi-touch helper aggregation:
        // horizontal = average bend, vertical = strongest vibrato, pressure = strongest expression.
        let x = active.map(\.x).reduce(0, +) / Double(active.count)
        let y = active.map(\.y).max() ?? 0
        let pressure = active.map(\.pressure).max() ?? 0

        midi?.sendHelperGesture(
            x: x,
            y: y,
            pressure: pressure,
            controls: helperControls,
            channel: helperTargetChannel,
            pitchBendRange: helperPitchBendRange,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
    }

    private func updateTouchInstrumentSustain(_ states: [TouchPerformanceState]) {
        let config = currentTouchConfiguration
        let settings = MIDIHelperSustainSettings(
            trackpadEnabled: config.trackpadSustainEnabled &&
                config.surfaceSelection.accepts(.trackpad),
            trackpadContactThreshold: config.trackpadSustainThreshold,
            magicMouseEnabled: config.magicMouseSustainEnabled &&
                config.surfaceSelection.accepts(.magicMouse),
            magicMouseGesture: config.magicMouseSustainGesture,
            trackpadGesture: config.trackpadSustainGesture
        )
        let active = states.filter(\.isTouching)
        let snapshot = touchSustainState.update(
            trackpadContactSizes: active.filter { $0.surface == .trackpad }.map(\.pressure),
            magicMouseTouching: active.contains { $0.surface == .magicMouse },
            settings: settings,
            trackpadClickDown: physicalTrackpadDown,
            magicMouseClickDown: physicalMouseDown
        )
        touchInstrumentSustainActive = snapshot.isActive
        if touchRunning && touchMIDIOutEnabled {
            midi?.setTouchSustain(
                snapshot.isActive,
                configuration: config,
                midiMode: touchMIDIMode,
                baseChannel: touchMIDIChannel
            )
        }
    }

    /// CGEventTap click events are not tagged with a reliable Magic Mouse vs
    /// Trackpad identity. Attribute them only when exactly one surface has an
    /// active finger, or when the input view has selected exactly one surface.
    /// When both are touched, ignore ambiguous clicks rather than misroute CC64.
    private func handlePhysicalClick(_ down: Bool) {
        if down {
            let states = midiHelperRunning ? midiHelperStates : touchStates
            let touched = Set(states.filter(\.isTouching).map(\.surface))
            let surface: TouchSurfaceKind?
            if touched.count == 1 {
                surface = touched.first
            } else if touched.isEmpty {
                let selection = midiHelperRunning
                    ? helperSurfaceSelection : currentTouchConfiguration.surfaceSelection
                switch selection {
                case .trackpad: surface = .trackpad
                case .magicMouse: surface = .magicMouse
                case .both: surface = nil
                }
            } else {
                surface = nil
            }
            lastClickSurface = surface
            if surface == .trackpad { physicalTrackpadDown = true }
            if surface == .magicMouse { physicalMouseDown = true }
        } else {
            if lastClickSurface == .trackpad { physicalTrackpadDown = false }
            if lastClickSurface == .magicMouse { physicalMouseDown = false }
            lastClickSurface = nil
        }

        if midiHelperRunning {
            handleMIDIHelperStates(midiHelperStates)
        } else if touchRunning {
            updateTouchInstrumentSustain(touchStates)
        }
    }

    func enableInputControls() {
        if inputCapture == nil {
            let capture = ExpressiveInputCapture()
            capture.onCaptureChanged = { [weak self] captured in
                Task { @MainActor in
                    guard let self else { return }
                    self.mouseCaptureActive = captured
                    self.inputControlsStatus = captured
                        ? "Captured · mouse motion is blocked from the desktop"
                        : "Armed · mouse is controlling the desktop"
                }
            }
            capture.onPhysicalClick = { [weak self] down in
                Task { @MainActor in self?.handlePhysicalClick(down) }
            }
            capture.onPanic = { [weak self] in
                Task { @MainActor in self?.panicStop() }
            }
            capture.onTapDisabled = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.panicStop()
                    self.inputControlsStatus = "Event tap disabled by macOS · Panic Stop"
                }
            }
            inputCapture = capture
        }

        guard let inputCapture else { return }
        inputCapture.setHotkey(captureHotkey)
        do {
            try inputCapture.install()
            inputControlsArmed = true
            mouseCaptureActive = false
            inputControlsStatus = "Armed · press \(captureHotkey.displayText) to capture/release pointer"
        } catch {
            inputControlsArmed = false
            mouseCaptureActive = false
            lastError = error.localizedDescription
            inputControlsStatus = error.localizedDescription
        }
    }

    func disableInputControls() {
        inputCapture?.stop()
        inputControlsArmed = false
        mouseCaptureActive = false
        physicalTrackpadDown = false
        physicalMouseDown = false
        lastClickSurface = nil
        inputControlsStatus = "Off · mouse controls the desktop normally"
        if midiHelperRunning {
            handleMIDIHelperStates(midiHelperStates)
        } else if touchRunning {
            updateTouchInstrumentSustain(touchStates)
        }
    }

    func setCaptureHotkey(_ key: CaptureHotkey) {
        captureHotkey = key
        inputCapture?.setHotkey(key)
        if inputControlsArmed {
            inputControlsStatus = "Armed · press \(key.displayText) to capture/release pointer"
        }
    }

    func setMouseCapture(_ captured: Bool) {
        guard inputControlsArmed else { return }
        inputCapture?.setCaptured(captured)
    }

    func playMIDIFile(_ url: URL) {
        guard requireEngine() else { return }
        do {
            let data = try Data(contentsOf: url)
            let midi = try MIDIFileParser.parse(data)
            currentFileName = url.lastPathComponent
            playback?.play(events: MIDIFileParser.hapticEvents(from: midi), masterLevel: masterLevel)
            isPlaying = true
        } catch { fail(error) }
    }

    func playAudioFile(_ url: URL, profile: AudioHapticProfile? = nil) {
        guard requireEngine() else { return }
        currentFileName = url.lastPathComponent
        let selectedProfile = profile ?? activeProfile
        let fileURL = url
        isPlaying = true
        Task {
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try AudioFileHapticService.render(url: fileURL, profile: selectedProfile)
                }.value
                playback?.play(events: events, masterLevel: masterLevel)
                isPlaying = false
            } catch {
                fail(error)
            }
        }
    }

    func handleDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "mid" || ext == "midi" { playMIDIFile(url) }
        else { playAudioFile(url) }
    }

    func startSystemAudio() {
        guard requireEngine(), let systemAudio else { return }
        Task {
            do {
                try await systemAudio.start(profile: activeProfile, masterLevel: masterLevel)
                systemAudioRunning = true
                engineStatus = "System audio is being converted to trackpad haptics"
            } catch { fail(error) }
        }
    }

    func stopSystemAudio() {
        Task {
            await systemAudio?.stop()
            systemAudioRunning = false
            engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
        }
    }

    private func requireEngine() -> Bool {
        if engineReady { return true }
        prepareEngine()
        return engineReady
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        engineStatus = "Error"
        isPlaying = false
    }
}
#endif
