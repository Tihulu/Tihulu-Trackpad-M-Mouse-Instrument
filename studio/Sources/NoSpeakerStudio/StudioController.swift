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
    @Published private(set) var chordBank = StudioController.readChordBank()
    @Published private(set) var chordArmed = false
    @Published private(set) var chordActiveSlots: Set<Int> = []
    @Published private(set) var chordStatus = "MIDI output off"
    private let chordOutput = ChordMIDIOutput()
    private var chordState = ChordPadState()
    private var chordTimers: [Int: Task<Void, Never>] = [:]
    private var chordTimerTokens: [Int: UUID] = [:]
    private var chordOutstanding: Set<SensorDestination> = []
    @Published var touchRunning = false
    @Published var touchPreviewRunning = false
    @Published var touchContact = TrackpadContact()
    @Published var magicMouseOrientation = SurfaceOrientation(rawValue: UserDefaults.standard.string(forKey: "TIHULU.magicMouseOrientation") ?? "") ?? .horizontal
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
    @Published var touchBarProfile = StudioController.readTouchBarProfile()
    @Published var touchBarSustainOn = false
    @Published var simulatedHingeAngle = 90.0
    @Published var liveHingeEnabled = false
    @Published var hingeSensorStatus = "Hardware sensor OFF · manual simulator available"
    @Published var activeMIDINotes: [ActiveMIDINote] = []
    @Published var systemAudioRunning = false
    @Published var systemAudioStarting = false
    @Published var systemAudioStopping = false
    @Published var speakerProfile: AudioHapticProfile = .voice
    @Published var speakerOptimized = true
    @Published var speakerAutomaticGain = true
    @Published var speakerNoiseGate = true
    @Published var speakerBufferMS = 150.0

    var speakerBusy: Bool { systemAudioRunning || systemAudioStarting || systemAudioStopping }
    private var speakerTask: Task<Void, Never>?
    private var speakerGeneration: UInt64 = 0
    @Published var lastMIDIMessage = "No MIDI received yet"
    @Published var currentFileName = "No file loaded"
    @Published var activeProfile: AudioHapticProfile = .fullMix

    private var driver: HapticTrackpadDriver?
    private var playback: HapticPlaybackEngine?
    nonisolated static let startupGreeting = "KOMUTAN LOGAR, BİR CİSİM YAKLAŞIYOR EFENDİM."
    private var startupGreetingAttempted = false
    private var startupGreetingPlaying = false
    private var startupGreetingTask: Task<Void, Never>?
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
    private var instrumentPreviewRequested = false
    private var helperPreviewRequested = false
    private var touchBarBridge: StudioTouchBarBridge?
    private var hingeSensor: MacBookHingeAngleSource?
    private var heldTouchBarNotes: Set<Int> = []
    private var clickedSurface: TouchSurfaceKind?
    private var trackpadClickPressure: Double?
    private var activeMIDINoteMap: [String: ActiveMIDINote] = [:]

    private static func readChordBank() -> ChordBank {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.chordBank.v1"),
              let document = try? WorkspaceArchive.decode(ChordBank.self, from: data),
              document.payload.isValid else { return ChordBank() }
        return document.payload
    }

    func updateChordBank(_ proposed: ChordBank) {
        guard proposed.isValid, !chordArmed, chordOutstanding.isEmpty else { return }
        chordBank = proposed
        if let data = try? WorkspaceArchive.encode(name: "Chord bank", payload: proposed) {
            UserDefaults.standard.set(data, forKey: "TIHULU.chordBank.v1")
        }
    }

    func armChordPads() {
        guard !chordArmed else { return }
        releaseChordPads()
        guard chordOutstanding.isEmpty else {
            chordStatus = "Unreleased MIDI notes. Reset the receiving DAW before retrying."
            return
        }
        do {
            try chordOutput.open()
            chordArmed = true
            chordStatus = "MIDI ready: TIHULU Chord Pads"
        } catch { chordStatus = error.localizedDescription }
    }

    func triggerChordPad(_ slot: Int) {
        guard chordArmed, let pad = chordBank.pad(at: slot) else { return }
        if chordState.activeSlots.contains(slot) {
            releaseChordPad(slot)
            if chordBank.latch || !chordArmed { return }
        }
        let commands = chordState.press(slot: slot, pad: pad, channel: chordBank.channel - 1,
                                        velocity: chordBank.velocity)
        guard deliverChordCommands(commands) else { return }
        chordActiveSlots = chordState.activeSlots
        if !chordBank.latch {
            let token = UUID()
            chordTimerTokens[slot] = token
            let duration = chordBank.gateMS
            chordTimers[slot] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
                guard let self, self.chordTimerTokens[slot] == token else { return }
                self.releaseChordPad(slot)
            }
        }
    }

    private func releaseChordPad(_ slot: Int) {
        chordTimers.removeValue(forKey: slot)?.cancel()
        chordTimerTokens.removeValue(forKey: slot)
        _ = deliverChordCommands(chordState.release(slot: slot))
        chordActiveSlots = chordState.activeSlots
    }

    private func deliverChordCommands(_ commands: [SensorCommand]) -> Bool {
        for command in commands {
            if command.value > 0 { chordOutstanding.insert(command.destination) }
            guard chordOutput.send(command) else {
                chordArmed = false
                releaseChordPads()
                chordStatus = "MIDI delivery failed. Check the DAW; note release is not confirmed."
                return false
            }
            if command.value == 0 { chordOutstanding.remove(command.destination) }
        }
        return true
    }

    func releaseChordPads() {
        for task in chordTimers.values { task.cancel() }
        chordTimers.removeAll()
        chordTimerTokens.removeAll()
        _ = chordState.releaseAll()
        chordActiveSlots = []
        // Retry all possibly transmitted notes, including a failed Note On.
        for key in Array(chordOutstanding) {
            if chordOutput.send(.init(key, value: 0)) { chordOutstanding.remove(key) }
        }
        if !chordOutstanding.isEmpty {
            chordArmed = false
            chordStatus = "Some MIDI releases failed. Reset the receiving DAW and retry Release All."
        }
    }

    func disarmChordPads() {
        releaseChordPads()
        chordArmed = false
        if chordOutstanding.isEmpty { chordStatus = "MIDI output off" }
    }

    private static func readSavedCaptureShortcut() -> PerformanceCaptureShortcut {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.captureShortcut"),
              let candidate = try? JSONDecoder().decode(PerformanceCaptureShortcut.self, from: data),
              candidate.isValid else { return .defaultShortcut }
        return candidate
    }

    private static func readTouchBarProfile() -> TouchBarProfile {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.touchBarProfile"),
              let profile = try? JSONDecoder().decode(TouchBarProfile.self, from: data)
        else { return TouchBarProfile() }
        return profile.normalized()
    }

    init() {
        prepareEngine()
    }

    func installTouchBar() {
        if touchBarBridge == nil {
            let bridge = StudioTouchBarBridge()
            bridge.controller = self
            touchBarBridge = bridge
        }
        touchBarBridge?.install(profile: touchBarProfile)
    }

    func setTouchBarProfile(_ proposed: TouchBarProfile) {
        let next = proposed.normalized()
        guard next != touchBarProfile else { return }
        releaseTouchBarNotes()
        if touchBarSustainOn {
            touchBarSustainOn = false
            midi?.releaseHelperSustain()
        }
        touchBarProfile = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "TIHULU.touchBarProfile")
        }
        touchBarBridge?.install(profile: next)
    }

    func releaseTouchBarNotes() {
        for note in heldTouchBarNotes {
            midi?.sendPerformanceNote(
                note: note, velocity: 0, isOn: false, channel: touchBarProfile.channel
            )
        }
        heldTouchBarNotes.removeAll()
    }

    func touchBarKey(_ note: Int, pressed: Bool) {
        cancelStartupGreeting()
        if !midiRunning { startMIDI() }
        guard midiRunning else { return }
        let safeNote = max(0, min(127, note))
        if pressed {
            guard heldTouchBarNotes.insert(safeNote).inserted else { return }
        } else {
            guard heldTouchBarNotes.remove(safeNote) != nil else { return }
        }
        midi?.sendPerformanceNote(
            note: safeNote,
            velocity: touchBarProfile.noteVelocity,
            isOn: pressed,
            channel: touchBarProfile.channel
        )
    }

    func touchBarValue(_ zone: TouchBarZone, normalized value: Double) {
        cancelStartupGreeting()
        if !midiRunning { startMIDI() }
        guard midiRunning, value.isFinite else { return }
        let safe = max(0, min(1, value))
        let channel = touchBarProfile.channel
        switch zone {
        case .pitchBend, .fretless:
            midi?.sendHelperControls(
                x: safe, y: 0.5, contactSize: 0.5,
                assignments: MIDIHelperAssignments(
                    vibrato: false, pitchBend: true, expression: false
                ),
                channel: channel, pitchBendRange: helperPitchBendRange,
                vibratoCC: 1, expressionCC: 11
            )
        case .vibrato:
            midi?.sendControlChange(controller: 1, value: Int((safe * 127).rounded()), channel: channel)
        case .expression:
            midi?.sendControlChange(controller: 11, value: Int((safe * 127).rounded()), channel: channel)
        case .filter:
            midi?.sendControlChange(controller: 74, value: Int((safe * 127).rounded()), channel: channel)
        case .keys, .sustain:
            break
        }
    }

    func touchBarSustainPressed(_ isPressed: Bool) {
        cancelStartupGreeting()
        if !midiRunning { startMIDI() }
        guard midiRunning else { return }
        let next = touchBarProfile.sustainMode == .toggle
            ? (isPressed ? !touchBarSustainOn : touchBarSustainOn)
            : isPressed
        guard next != touchBarSustainOn else { return }
        touchBarSustainOn = next
        let helperHoldsSameChannel = midiHelperRunning && midiHelperSustainActive &&
            helperTargetChannel == touchBarProfile.channel
        midi?.setHelperSustain(next || helperHoldsSameChannel, channel: touchBarProfile.channel)
    }

    func enableLiveHinge(_ enable: Bool) {
        if enable && !allowOtherPerformance() { return }
        if !enable {
            hingeSensor?.stop()
            hingeSensor = nil
            liveHingeEnabled = false
            hingeSensorStatus = "Hardware sensor OFF · manual simulator available"
            return
        }
        guard !liveHingeEnabled else { return }
        let sensor = MacBookHingeAngleSource()
        sensor.onAngle = { [weak self] degrees in
            self?.applySimulatedHingeAngle(degrees)
        }
        if sensor.start() {
            hingeSensor = sensor
            liveHingeEnabled = true
            hingeSensorStatus = "Live hardware angle sensor active · MIDI mappings enabled"
        } else {
            hingeSensorStatus = sensor.status
            liveHingeEnabled = false
        }
    }

    func applySimulatedHingeAngle(_ degrees: Double) {
        simulatedHingeAngle = degrees
        guard let value = touchBarProfile.normalizedTilt(degrees) else { return }
        switch touchBarProfile.tiltTarget {
        case .disabled: break
        case .filter: touchBarValue(.filter, normalized: value)
        case .expression: touchBarValue(.expression, normalized: value)
        case .vibrato: touchBarValue(.vibrato, normalized: value)
        case .pitchBend: touchBarValue(.pitchBend, normalized: value)
        }
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
        disarmChordPads()
        cancelStartupGreeting()
        enableLiveHinge(false)
        releaseTouchBarNotes()
        touchBarSustainOn = false
        captureMonitor?.stop()
        captureArmed = false
        captureHotkeyArmed = false
        clickedSurface = nil
        trackpadClickPressure = nil
        stopSystemAudio()
        playback?.stop(closeDriver: true)
        touch?.stopPreview()
        midi?.stop()
        isPlaying = false
        touchRunning = false
        touchPreviewRunning = false
        instrumentPreviewRequested = false
        helperPreviewRequested = false
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
        disarmChordPads()
        cancelStartupGreeting()
        if speakerBusy { stopSystemAudio(); return }
        driver?.close()
        driver = nil
        prepareEngine()
    }

    /// Once per process, not on every SwiftUI appearance or reconnect.
    /// No non-Turkish fallback and no permission requests for the greeting.
    func playStartupGreetingOnce() {
        guard !startupGreetingAttempted else { return }
        startupGreetingAttempted = true
        guard engineReady, let engine = playback else { return }
        let message = Self.startupGreeting
        startupGreetingTask = Task { [weak self] in
            let events = try? await Task.detached(priority: .utility) { () throws -> [ScheduledHapticEvent] in
                let voices = VoiceHapticService.voiceOptions(language: .turkish)
                guard let voice = voices.first(where: { $0.id == "say:Yelda" })
                        ?? voices.first(where: { $0.backend == .say })
                        ?? voices.first(where: { $0.backend == .avSpeech }) else { return [] }
                return try VoiceHapticService.render(text: message, voice: voice.id)
            }.value
            guard !Task.isCancelled, let self, self.engineReady,
                  self.playback === engine, !self.isPlaying,
                  !self.touchRunning, !self.midiRunning, !self.midiHelperRunning,
                  !self.systemAudioRunning, let events, !events.isEmpty else { return }
            self.startupGreetingPlaying = true
            engine.play(events: events, masterLevel: self.masterLevel)
        }
    }

    private func cancelStartupGreeting() {
        startupGreetingAttempted = true
        startupGreetingTask?.cancel()
        startupGreetingTask = nil
        if startupGreetingPlaying {
            playback?.stop(closeDriver: false)
            startupGreetingPlaying = false
        }
    }

    func speak(_ text: String, voice: String?) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        do {
            let events = try HapticPatternRenderer.notes(.init(bpm: bpm, stepsPerBeat: 4, length: length, steps: steps))
            playback?.play(events: events, masterLevel: masterLevel, loop: loop)
            isPlaying = true
        } catch { fail(error) }
    }

    func playDrums(_ hits: [DrumStep], length: Int = 16, loop: Bool = false) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        let events = HapticPatternRenderer.drums(.init(bpm: bpm, stepsPerBeat: 4, length: length, hits: hits))
        playback?.play(events: events, masterLevel: masterLevel, loop: loop)
        isPlaying = true
    }

    func stopPlayback() {
        cancelStartupGreeting()
        playback?.stop(closeDriver: false)
        isPlaying = false
    }

    func testTone(frequency: Double) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        let duration = max(2, (0.04 * frequency).rounded()) / frequency * 1_000
        playback?.play(frame: .init(tones: [.init(frequencyHz: frequency)], durationMS: duration, level: masterLevel))
    }

    func sweep() {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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

    var touchSessionSummary: String {
        guard touchRunning else { return "Melodic notes or drums; independent surface outputs" }
        return currentTouchConfiguration.surfaceSelection.rawValue + " · " +
            (currentTouchConfiguration.fretless ? "Fretless" : "Fretted / drums")
    }

    var helperSessionSummary: String {
        guard midiHelperRunning else { return "Pitch bend, vibrato, expression and sustain" }
        return helperSurfaceSelection.rawValue + " · MIDI channel " + String(helperTargetChannel + 1)
    }

    func setMagicMouseOrientation(_ newOrientation: SurfaceOrientation) {
        guard magicMouseOrientation != newOrientation else { return }
        magicMouseOrientation = newOrientation
        UserDefaults.standard.set(newOrientation.rawValue, forKey: "TIHULU.magicMouseOrientation")
        var updated = currentTouchConfiguration
        updated.magicMouseOrientation = newOrientation
        updateTouchConfiguration(updated)
    }

    /// Only one native MultitouchSupport callback can be registered per device.
    /// Distribute the same physical frames to independently enabled Instrument
    /// and Helper consumers, filtered by surface assignment.
    private func refreshSharedSurfaceMonitoring() {
        guard let touch else { return }
        let needed = instrumentPreviewRequested || helperPreviewRequested ||
                     touchRunning || midiHelperRunning
        if !needed {
            touch.stopPreview()
            touchPreviewRunning = false
            return
        }

        var monitoringConfiguration = currentTouchConfiguration
        monitoringConfiguration.surfaceSelection = .both
        monitoringConfiguration.magicMouseOrientation = magicMouseOrientation
        // A Helper-only surface must not accidentally produce Instrument
        // haptics, even when the Instrument is playing on the other surface.
        if !currentTouchConfiguration.surfaceSelection.accepts(.trackpad) {
            monitoringConfiguration.trackpadOutput = .midiInstrument
        }
        if !currentTouchConfiguration.surfaceSelection.accepts(.magicMouse) {
            monitoringConfiguration.magicMouseOutput = .midiInstrument
        }

        if touchPreviewRunning {
            touch.update(configuration: monitoringConfiguration)
            return
        }

        do {
            try touch.startPreview(configuration: monitoringConfiguration) { [weak self] states in
                Task { @MainActor in
                    self?.handleSharedSurfaceStates(states)
                }
            }
            touchPreviewRunning = true
        } catch {
            fail(error)
        }
    }

    private func handleSharedSurfaceStates(_ states: [TouchPerformanceState]) {
        if instrumentPreviewRequested || touchRunning {
            let instrumentStates = states.filter {
                currentTouchConfiguration.surfaceSelection.accepts($0.surface)
            }
            handleTouchStates(instrumentStates)
        }
        if helperPreviewRequested || midiHelperRunning {
            let helperStates = states.filter {
                helperSurfaceSelection.accepts($0.surface)
            }
            handleMIDIHelperStates(helperStates)
        }
    }

    func startTouchPreview(configuration: TouchInstrumentConfiguration) {
        guard requireEngine() else { return }
        // Reopening the view never overwrites an already running performance
        // with fresh @State defaults from a newly constructed SwiftUI view.
        if touchRunning {
            instrumentPreviewRequested = true
            refreshSharedSurfaceMonitoring()
            return
        }
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        currentTouchConfiguration = configuration
        instrumentPreviewRequested = true
        refreshSharedSurfaceMonitoring()
        if !touchRunning && !midiHelperRunning {
            engineStatus = "Touch preview active · no MIDI or haptic output until Start"
        }
    }

    func updateTouchConfiguration(_ configuration: TouchInstrumentConfiguration) {
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        currentTouchConfiguration = configuration
        refreshSharedSurfaceMonitoring()
    }

    func stopTouchPreview() {
        // Navigation drops only the UI preview request, never a live session.
        instrumentPreviewRequested = false
        guard !touchRunning else { return }
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        midi?.endAllTouchOutput()
        touchStates = []
        touchContact = TrackpadContact()
        refreshSharedSurfaceMonitoring()
        if !midiHelperRunning { engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus }
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine(), let touch else { return }
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        currentTouchConfiguration = configuration
        touchMIDIOutEnabled = midiOut
        touchMIDIMode = midiMode
        touchMultiTouchEnabled = multiTouch
        touchMIDIChannel = max(0, min(15, midiChannel))
        touchSustainSettings = sustainSettings
        touchSustainState.reset()

        if !instrumentPreviewRequested {
            startTouchPreview(configuration: configuration)
        } else {
            updateTouchConfiguration(configuration)
        }
        guard touchPreviewRunning else { return }

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
        if !instrumentPreviewRequested {
            touchStates = []
            touchContact = TrackpadContact()
        }
        refreshSharedSurfaceMonitoring()
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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
        // Do not disconnect the virtual MIDI endpoint while an independently
        // enabled Touch Instrument or MIDI Helper still needs Logic.
        if (touchRunning && touchMIDIOutEnabled) || midiHelperRunning {
            engineStatus = "MIDI remains active for running instruments"
            return
        }
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
        guard requireEngine() else { return }
        // Preserve the live helper's previously chosen surface until the user
        // explicitly changes it; navigating away/back must not re-route MIDI.
        if midiHelperRunning {
            helperPreviewRequested = true
            refreshSharedSurfaceMonitoring()
            return
        }
        helperSurfaceSelection = surfaceSelection
        helperPreviewRequested = true
        refreshSharedSurfaceMonitoring()
        if !touchRunning && !midiHelperRunning {
            engineStatus = "MIDI Helper preview active"
        }
    }

    func updateMIDIHelperSurface(_ surfaceSelection: TouchSurfaceSelection) {
        helperSurfaceSelection = surfaceSelection
        refreshSharedSurfaceMonitoring()
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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

        if !helperPreviewRequested {
            startMIDIHelperPreview(surfaceSelection: surfaceSelection)
        } else {
            updateMIDIHelperSurface(surfaceSelection)
        }
        guard touchPreviewRunning else { return }

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
        if !helperPreviewRequested { midiHelperStates = [] }
        refreshSharedSurfaceMonitoring()
        stopCaptureMonitorIfIdle()
        engineStatus = touchPreviewRunning ? "Surface monitoring active" : "MIDI bridge active"
    }

    func stopMIDIHelperPreview() {
        helperPreviewRequested = false
        guard !midiHelperRunning else { return }
        midiHelperStates = []
        refreshSharedSurfaceMonitoring()
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
        midi?.setHelperSustain(
            snapshot.isActive || (touchBarSustainOn && touchBarProfile.channel == helperTargetChannel),
            channel: helperTargetChannel
        )

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
            let currentStates = midiHelperStates + touchStates
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
        if midiHelperRunning { handleMIDIHelperStates(midiHelperStates) }
        if touchRunning { updateTouchSustain(touchStates) }
    }

    private func handlePhysicalPressure(_ pressure: Double) {
        guard clickedSurface == .trackpad else { return }
        trackpadClickPressure = pressure
        if midiHelperRunning { handleMIDIHelperStates(midiHelperStates) }
        if touchRunning { updateTouchSustain(touchStates) }
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
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
        cancelStartupGreeting()
        guard !speakerBusy else { return }
        guard !touchRunning, !midiHelperRunning, !midiRunning, !isPlaying, !liveHingeEnabled else {
            lastError = "Stop other performances and the MIDI bridge before starting Trackpad Speaker. The haptic motor is shared."
            return
        }
        guard requireEngine(), let systemAudio else { return }
        playback?.stop(closeDriver: false)
        speakerGeneration &+= 1
        let token = speakerGeneration
        systemAudioStarting = true
        engineStatus = "Starting system audio capture"
        speakerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await systemAudio.start(profile: speakerProfile, masterLevel: masterLevel,
                    speechOptimized: speakerOptimized, automaticGain: speakerAutomaticGain,
                    noiseGate: speakerNoiseGate, bufferSeconds: speakerBufferMS / 1000,
                    onFailure: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.speakerGeneration == token else { return }
                            self.stopSystemAudio()
                            self.lastError = "System audio stopped: " + message
                        }
                    })
                guard !Task.isCancelled, speakerGeneration == token else { return }
                systemAudioStarting = false
                systemAudioRunning = true
                engineStatus = "System audio active · buffered playback"
            } catch {
                guard speakerGeneration == token else { return }
                systemAudioStarting = false
                systemAudioRunning = false
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    func stopSystemAudio() {
        guard speakerBusy, !systemAudioStopping else { return }
        speakerGeneration &+= 1
        let token = speakerGeneration
        let oldTask = speakerTask
        let capture = systemAudio
        oldTask?.cancel()
        capture?.stopOutput()
        systemAudioRunning = false
        systemAudioStarting = false
        systemAudioStopping = true
        speakerTask = Task { [weak self] in
            await oldTask?.value
            await capture?.stop()
            guard let self, self.speakerGeneration == token else { return }
            self.systemAudioStopping = false
            self.speakerTask = nil
            if self.engineReady { self.engineStatus = "Force Touch trackpad ready" }
        }
    }

    private func allowOtherPerformance() -> Bool {
        guard !speakerBusy else {
            lastError = "Stop Trackpad Speaker before using another haptic or MIDI performance."
            return false
        }
        return true
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
