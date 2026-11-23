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
    @Published var pointerCaptured = false
    @Published var captureArmed = false
    @Published var captureShortcut = StudioController.readSavedCaptureShortcut()
    @Published var captureStatus = "Cursor free · capture is OFF by default"
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

    private var helperAssignments = MIDIHelperAssignments.hybrid
    private var helperSendToDAW = true
    private var helperTargetChannel = 0
    private var helperPitchBendRange = 12
    private var helperVibratoCC = 1
    private var helperExpressionCC = 11
    private var helperLocalSound = false
    private var helperSurfaceSelection: TouchSurfaceSelection = .trackpad
    private var helperSustainSettings = MIDIHelperSustainSettings()
    private var helperSustainState = MIDIHelperSustainState()
    private var touchSustainSettings = MIDIHelperSustainSettings()
    private var touchSustainState = MIDIHelperSustainState()
    private var captureMonitor: PerformanceCaptureMonitor?
    private var captureHotkeyArmed = false
    private var clickedSurface: TouchSurfaceKind?
    private var trackpadClickPressure: Double?
    private var activeMIDINoteMap: [String: ActiveMIDINote] = [:]

    private static func readSavedCaptureShortcut() -> PerformanceCaptureShortcut {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.captureShortcut"),
              let candidate = try? JSONDecoder().decode(PerformanceCaptureShortcut.self, from: data),
              candidate.isValid else { return .defaultShortcut }
        return candidate
    }

    init() {
        prepareEngine()
    }

    func prepareEngine() {
        // A reconnect replaces the device and input monitor. Stop the previous
        // dedicated event thread before replacing its owner, so no stale
        // filtering tap can survive and interfere with desktop pointer input.
        captureMonitor?.stop()
        captureMonitor = nil
        do {
            let driver = try HapticTrackpadDriver()
            try driver.open()
            self.driver = driver
            self.playback = HapticPlaybackEngine(driver: driver)
            self.touch = TouchInstrumentService(driver: driver)
            self.midi = MIDIHapticService(driver: driver)
            self.systemAudio = SystemAudioHapticCapture(driver: driver)
            let capture = PerformanceCaptureMonitor()
            capture.onCaptureChanged = { [weak self] captured in
                Task { @MainActor in
                    guard let self else { return }
                    self.pointerCaptured = captured
                    if self.captureArmed || self.touchRunning || self.midiHelperRunning {
                        self.captureStatus = captured
                            ? "Cursor captured · press the shortcut again or Esc"
                            : "Cursor free · event monitor active"
                    }
                }
            }
            capture.onPanic = { [weak self] in
                Task { @MainActor in self?.panicStop() }
            }
            capture.onPhysicalClick = { [weak self] down, pressure in
                Task { @MainActor in self?.handlePhysicalClick(down, pressure: pressure) }
            }
            capture.onPhysicalPressure = { [weak self] pressure in
                Task { @MainActor in self?.handlePhysicalPressure(pressure) }
            }
            capture.onMonitorRecovered = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.pointerCaptured = false
                    // A click-up event may have been lost while the tap timed out.
                    // Release any synthetic sustain state instead of sticking CC64.
                    self.handlePhysicalClick(false, pressure: 0)
                    self.captureStatus = "Input monitor recovered after timeout · cursor released · press the capture shortcut to resume"
                }
            }
            capture.onMonitorFailed = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // macOS can disable a global event tap while the haptic driver
                    // is still healthy. Never escalate that to a device panic.
                    self.captureMonitor?.stop()
                    self.handlePhysicalClick(false, pressure: 0)
                    self.captureArmed = false
                    self.captureHotkeyArmed = false
                    self.clickedSurface = nil
                    self.trackpadClickPressure = nil
                    self.pointerCaptured = false
                    self.captureStatus = "macOS disabled input monitoring · cursor free · enable Global Capture again to retry"
                    // Preserve Voice/Touch/MIDI/Audio playback and the live driver.
                }
            }
            self.captureMonitor = capture
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
        captureMonitor?.stop()
        captureArmed = false
        captureHotkeyArmed = false
        clickedSurface = nil
        trackpadClickPressure = nil
        playback?.stop(closeDriver: true)
        touch?.stopPreview()
        midi?.stop()
        Task { await systemAudio?.stop() }
        isPlaying = false
        touchRunning = false
        touchPreviewRunning = false
        midiHelperRunning = false
        helperSustainState.reset()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
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
        pointerCaptured = false
        captureStatus = "Stopped · cursor released"
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
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touch?.stopPreview()
        midi?.endAllTouchOutput()
        touchPreviewRunning = false
        touchRunning = false
        touchMIDIOutEnabled = false
        touchStates = []
        touchContact = TrackpadContact()
        engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
        stopCaptureMonitorIfIdle()
    }

    func startTouch(
        configuration: TouchInstrumentConfiguration,
        midiOut: Bool,
        midiMode: TouchMIDIMode = .standard,
        multiTouch: Bool = true,
        midiChannel: Int = 0,
        sustainSettings: MIDIHelperSustainSettings = .init()
    ) {
        guard requireEngine(), let touch else { return }
        currentTouchConfiguration = configuration
        touchMIDIOutEnabled = midiOut
        touchMIDIMode = midiMode
        touchMultiTouchEnabled = multiTouch
        touchMIDIChannel = max(0, min(15, midiChannel))
        touchSustainSettings = sustainSettings
        touchSustainState.reset()

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
        startPerformanceEventMonitor()
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
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touch?.setActive(false)
        midi?.endAllTouchOutput()
        touchRunning = false
        touchMIDIOutEnabled = false
        engineStatus = touchPreviewRunning
            ? "Touch preview active · no MIDI or haptic output until Start"
            : (engineReady ? "Force Touch trackpad ready" : engineStatus)
        stopCaptureMonitorIfIdle()
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

        guard touchRunning else { return }
        if touchMIDIOutEnabled {
            midi?.sendTouchStates(
                states,
                configuration: currentTouchConfiguration,
                midiMode: touchMIDIMode,
                baseChannel: touchMIDIChannel,
                multiTouchEnabled: touchMultiTouchEnabled
            )
        }
        updateTouchSustain(states)
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
        captureMonitor?.releasePointer()
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
        midi?.resetHelperControls(
            assignments: helperAssignments,
            channel: helperTargetChannel,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
        midi?.stop()
        midiRunning = false
        stopCaptureMonitorIfIdle()
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
        assignments: MIDIHelperAssignments,
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
        trackpadSustainGesture: TrackpadSustainGesture = .contactThreshold,
        trackpadSustainSensor: TrackpadSustainSensor = .contactSize
    ) {
        let newSustainSettings = MIDIHelperSustainSettings(
            trackpadEnabled: trackpadSustainEnabled,
            trackpadContactThreshold: trackpadSustainThreshold,
            magicMouseEnabled: magicMouseSustainEnabled,
            magicMouseGesture: magicMouseSustainGesture,
            trackpadGesture: trackpadSustainGesture,
            trackpadSensor: trackpadSustainSensor
        )
        let newChannel = max(0, min(15, targetChannel))
        if midiHelperRunning &&
            (newSustainSettings != helperSustainSettings ||
             assignments != helperAssignments ||
             newChannel != helperTargetChannel ||
             sendToDAW != helperSendToDAW ||
             surfaceSelection != helperSurfaceSelection) {
            midi?.resetHelperControls(
                assignments: helperAssignments,
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
        helperAssignments = assignments
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
        startPerformanceEventMonitor()
        engineStatus = "MIDI Helper active · expressive CC mapping"
    }

    func stopMIDIHelper() {
        midi?.releaseHelperSustain()
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        midi?.resetHelperControls(
            assignments: helperAssignments,
            channel: helperTargetChannel,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
        midi?.setInputHapticsEnabled(true)
        midiHelperRunning = false
        stopCaptureMonitorIfIdle()
        engineStatus = touchPreviewRunning ? "MIDI Helper preview active" : "MIDI bridge active"
    }

    func stopMIDIHelperPreview() {
        if midiHelperRunning {
            stopMIDIHelper()
        }
        touch?.stopPreview()
        touchPreviewRunning = false
        midiHelperStates = []
        stopCaptureMonitorIfIdle()
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
            trackpadClickDown: clickedSurface == .trackpad,
            magicMouseClickDown: clickedSurface == .magicMouse,
            trackpadClickPressure: trackpadClickPressure
        )
        midiHelperTrackpadSustainActive = snapshot.trackpadActive
        midiHelperMagicMouseSustainActive = snapshot.magicMouseActive
        midiHelperSustainActive = snapshot.isActive && helperSendToDAW

        guard helperSendToDAW else {
            midi?.releaseHelperSustain()
            return
        }
        midi?.setHelperSustain(snapshot.isActive, channel: helperTargetChannel)

        guard !active.isEmpty else {
            midi?.resetHelperControls(
                assignments: helperAssignments,
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

        midi?.sendHelperControls(
            x: x,
            y: y,
            contactSize: pressure,
            assignments: helperAssignments,
            channel: helperTargetChannel,
            pitchBendRange: helperPitchBendRange,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC
        )
    }

    /// Read-only report for the Diagnostics panel. Never records key contents,
    /// typed text, device identifiers, user paths, or private recordings.
    func globalCaptureDiagnosticReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let build = Bundle.main.infoDictionary?["NoSpeakerBuildSHA"] as? String ?? "unknown"
        guard let snapshot = captureMonitor?.diagnosticSnapshot() else {
            return """
            TIHULU Global Capture Diagnostics
            App version: \(version), build: \(build)
            macOS: \(os)
            Capture monitor: NOT INITIALIZED
            Haptic engine ready: \(engineReady)
            Last engine status: \(engineStatus)
            Action: Check the engine error in the top bar and use Reconnect.
            """
        }

        func yesNo(_ yes: Bool) -> String { yes ? "YES" : "NO" }

        let suggestion: String
        if !snapshot.accessibilityGranted {
            suggestion = "Accessibility permission not granted. Enable this installed app in Privacy & Security > Accessibility, then quit and reopen."
        } else if !snapshot.inputMonitoringGranted && !snapshot.eventTapEnabled {
            suggestion = "Input Monitoring preflight is not granted and the event tap is inactive. Inspect Privacy & Security > Input Monitoring, quit and reopen."
        } else if captureArmed && !snapshot.eventTapCreated {
            suggestion = "Capture is armed, but no event tap exists. Disable and re-enable Global Capture; inspect the status and macOS permissions."
        } else if captureArmed && !snapshot.eventTapEnabled {
            suggestion = "Capture is armed, but macOS reports the event tap disabled. Re-enable Global Capture; check the timeout/disable counters."
        } else if !captureArmed {
            suggestion = "Global Capture is OFF. Arm it, refresh this report, switch to another app, press the recorded shortcut twice, then refresh again."
        } else if snapshot.shortcutMatches == 0 {
            suggestion = "Tap is enabled but no shortcut match has been observed since app start. Press the recorded combination in another app and compare Key downs / Shortcut matches."
        } else {
            suggestion = "Shortcut matches are observed. If the cursor still moves when captured, compare pointer counts and Pointer captured while using another app."
        }

        return """
        TIHULU Global Capture Diagnostics (read-only)
        App version: \(version)
        Build: \(build)
        macOS: \(os)
        Haptic engine ready: \(yesNo(engineReady))
        Global Capture toggle: \(yesNo(captureArmed))
        Recorded shortcut: \(captureShortcut.displayName)
        Accessibility trusted: \(yesNo(snapshot.accessibilityGranted))
        Input Monitoring preflight: \(yesNo(snapshot.inputMonitoringGranted))
        Event tap created: \(yesNo(snapshot.eventTapCreated))
        Event tap enabled by macOS: \(yesNo(snapshot.eventTapEnabled))
        Dedicated capture thread: \(yesNo(snapshot.dedicatedInputThread))
        Monitor listening flag: \(yesNo(snapshot.listening))
        Shortcut armed inside monitor: \(yesNo(snapshot.shortcutArmed))
        Pointer captured: \(yesNo(snapshot.pointerCaptured))
        Key-down events observed: \(snapshot.keyDownEvents)
        Pointer events observed: \(snapshot.pointerEvents)
        Matched shortcuts: \(snapshot.shortcutMatches)
        Event tap timeouts: \(snapshot.tapTimeouts)
        Event tap disabled by system/user: \(snapshot.tapDisabledByUserInput)
        Last event tap status: \(snapshot.lastEventTapStatus)
        Current capture status: \(captureStatus)
        Touch instrument running: \(yesNo(touchRunning))
        Touch preview running: \(yesNo(touchPreviewRunning))
        MIDI helper running: \(yesNo(midiHelperRunning))
        Suggested next check: \(suggestion)

        Note: Counts start when this app process launches. The Input Monitoring
        preflight is an OS permission hint, not proof that a filtering event tap
        is operational. Raw keystrokes and typed text are NEVER saved here.
        """
    }

    func configurePerformanceCapture(
        armed: Bool,
        shortcut: PerformanceCaptureShortcut
    ) {
        guard shortcut.isValid else {
            lastError = "Escape is reserved for Panic Stop. Choose another key or key combination."
            return
        }
        captureShortcut = shortcut
        captureArmed = armed
        captureHotkeyArmed = armed
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "TIHULU.captureShortcut")
        }
        captureMonitor?.setShortcut(shortcut)
        captureMonitor?.setCaptureHotkeyEnabled(armed)
        if armed || touchRunning || midiHelperRunning {
            startPerformanceEventMonitor()
        } else {
            stopCaptureMonitorIfIdle()
        }
        if !armed {
            captureMonitor?.releasePointer()
            pointerCaptured = false
        }
    }

    private func startPerformanceEventMonitor() {
        // A user-armed shortcut remains available in Voice, MIDI,
        // Sequencers, Audio File, Speaker and Diagnostics, even before
        // a Touch/Helper performance starts. OFF remains the default.
        guard captureHotkeyArmed || touchRunning || midiHelperRunning else { return }
        guard let monitor = captureMonitor else { return }
        do {
            try monitor.start(shortcut: captureShortcut, requestPermissions: captureHotkeyArmed)
            monitor.setCaptureHotkeyEnabled(captureHotkeyArmed)
            captureStatus = captureHotkeyArmed
                ? "Ready globally · \(captureShortcut.displayName) toggles capture · Esc stops all"
                : "Cursor free · physical-click monitor active"
        } catch {
            captureStatus = "Global capture unavailable · check Accessibility and Input Monitoring permissions"
            if captureHotkeyArmed {
                lastError = error.localizedDescription
                captureArmed = false
                captureHotkeyArmed = false
                captureMonitor?.setCaptureHotkeyEnabled(false)
            }
            pointerCaptured = false
        }
    }

    private func stopCaptureMonitorIfIdle() {
        if !captureHotkeyArmed && !touchRunning && !midiHelperRunning {
            captureMonitor?.stop()
            clickedSurface = nil
            trackpadClickPressure = nil
            pointerCaptured = false
            captureStatus = "Cursor free · global capture OFF"
        }
    }

    private func handlePhysicalClick(_ down: Bool, pressure: Double) {
        if down {
            let currentStates = midiHelperRunning ? midiHelperStates : touchStates
            let touchedSurfaces = Set(
                currentStates.filter(\.isTouching).map(\.surface)
            )
            // Global CGEvent click does not identify its physical source.
            // Only assign it if exactly one surface has an active contact.
            clickedSurface = touchedSurfaces.count == 1 ? touchedSurfaces.first : nil
            trackpadClickPressure = clickedSurface == .trackpad ? pressure : nil
        } else {
            clickedSurface = nil
            trackpadClickPressure = nil
        }
        if midiHelperRunning {
            handleMIDIHelperStates(midiHelperStates)
        } else if touchRunning {
            updateTouchSustain(touchStates)
        }
    }

    private func handlePhysicalPressure(_ pressure: Double) {
        guard clickedSurface == .trackpad else { return }
        trackpadClickPressure = pressure
        if midiHelperRunning {
            handleMIDIHelperStates(midiHelperStates)
        } else if touchRunning {
            updateTouchSustain(touchStates)
        }
    }

    private func updateTouchSustain(_ states: [TouchPerformanceState]) {
        let active = states.filter(\.isTouching)
        let snapshot = touchSustainState.update(
            trackpadContactSizes: active
                .filter { $0.surface == .trackpad }
                .map(\.pressure),
            magicMouseTouching: active.contains { $0.surface == .magicMouse },
            settings: touchSustainSettings,
            trackpadClickDown: clickedSurface == .trackpad,
            magicMouseClickDown: clickedSurface == .magicMouse
        )
        let hapticsEnabled = currentTouchConfiguration.localHapticSound &&
            currentTouchConfiguration.selectedSurfaces.contains {
                currentTouchConfiguration.output(for: $0).sendsHaptics
            }
        touchInstrumentSustainActive = snapshot.isActive &&
            (touchMIDIOutEnabled || hapticsEnabled)
        touch?.setSustainActive(snapshot.isActive && hapticsEnabled)
        if touchMIDIOutEnabled {
            midi?.setTouchSustain(
                snapshot.isActive,
                baseChannel: touchMIDIChannel
            )
        }
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
