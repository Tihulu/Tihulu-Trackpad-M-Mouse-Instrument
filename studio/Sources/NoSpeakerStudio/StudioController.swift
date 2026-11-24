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

private enum ChordMPEConfigurationError: LocalizedError {
    case delivery
    var errorDescription: String? { "Could not configure the dedicated MPE output. Check CoreMIDI and re-arm." }
}

@MainActor
final class StudioController: ObservableObject {
    @Published var engineStatus = "Initializing haptic engine…"
    @Published var engineReady = false
    @Published var lastError: String?
    @Published var isPlaying = false
    @Published var masterLevel = 0.75 {
        didSet { updateChordHaptics(); updateTouchBarHaptics() }
    }
    @Published var bpm = 120.0
    @Published private(set) var sequenceRunning = false
    @Published private(set) var sequenceStatus = "Sequencer MIDI idle"
    private let sequenceMIDI = ChordMIDIOutput(name: "TIHULU Sequencer")
    private var sequenceLedger = MIDIClipNoteLedger()
    private var sequenceTask: Task<Void, Never>?
    private var sequenceToken: UUID?
    private var sequenceOwnsHaptics = false
    @Published var midiRunning = false
    @Published private(set) var chordBank = StudioController.readChordBank()
    @Published private(set) var chordArmed = false {
        didSet { touchBarBridge?.refreshChordControls() }
    }
    @Published private(set) var chordActiveSlots: Set<Int> = []
    @Published private(set) var chordStatus = "Output off"
    private let chordOutput = ChordMIDIOutput()
    private let chordMPEOutput = ChordMIDIOutput(name: "TIHULU Chord MPE")
    private var chordMPEState = ChordMPEState()
    // Retain the actual endpoint selection until all attempted notes are released.
    private var chordMPEActive = false
    private var activeChordMIDIOutput: ChordMIDIOutput { chordMPEActive ? chordMPEOutput : chordOutput }
    private var chordHaptics: LiveNoteHapticOutput?
    @Published private(set) var sharedNoteOutputEnabled = false
    private var sharedNoteOutput: SharedLiveNoteOutput?
    private var chordHapticToken: UUID?
    private var renderGeneration: UInt64 = 0
    private var engineGeneration: UInt64 = 0
    var chordOwnsHaptics: Bool { chordArmed && chordBank.effectiveOutput.sendsHaptics }
    @Published private(set) var touchBarOutputArmed = false
    @Published private(set) var touchBarOutputStatus = "Optional Trackpad output off"
    private var touchBarHaptics: LiveNoteHapticOutput?
    private let touchBarDedicatedMIDI = ChordMIDIOutput(name: "TIHULU Touch Bar")
    private var touchBarLocalState = TouchBarNoteState()
    private var touchBarOutstanding: Set<SensorDestination> = []
    private var touchBarOutputToken: UUID?
    private var nativePianoTokens: [Int: UUID] = [:]
    var touchBarOwnsHaptics: Bool { touchBarOutputArmed }
    var liveNoteOwnsHaptics: Bool { chordOwnsHaptics || touchBarOwnsHaptics }
    @Published private(set) var chordProgression = StudioController.readChordProgression()
    @Published private(set) var progressionRunning = false
    @Published private(set) var progressionStep: Int?
    @Published private(set) var progressionSingleSlot: Int?
    private var progressionTask: Task<Void, Never>?
    private var progressionToken: UUID?
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
    @Published private(set) var touchCustomScale: CustomScale?
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
        touchBarBridge?.refreshChordControls()
        if let data = try? WorkspaceArchive.encode(name: "Chord bank", payload: proposed) {
            UserDefaults.standard.set(data, forKey: "TIHULU.chordBank.v1")
        }
    }

    func setSharedNoteOutputEnabled(_ enabled: Bool) {
        guard !liveNoteOwnsHaptics else { return }
        sharedNoteOutputEnabled = enabled
    }

    private func makeLiveNoteOutput(driver: HapticTrackpadDriver, source: HapticMixSource) -> LiveNoteHapticOutput {
        if sharedNoteOutputEnabled {
            if sharedNoteOutput == nil { sharedNoteOutput = SharedLiveNoteOutput(driver: driver) }
            return LiveNoteHapticOutput(driver: driver, shared: sharedNoteOutput, sourceKind: source)
        }
        return LiveNoteHapticOutput(driver: driver, sourceKind: source)
    }

    private func releaseSharedOutputIfIdle() {
        guard chordHaptics == nil, touchBarHaptics == nil else { return }
        sharedNoteOutput?.retire()
        sharedNoteOutput = nil
    }

    func armChordPads() {
        guard !chordArmed else { return }
        releaseChordPads()
        guard chordOutstanding.isEmpty else {
            chordStatus = "Unreleased MIDI notes. Reset the receiving DAW before retrying."
            return
        }
        let selected = chordBank.effectiveOutput
        guard chordBank.permitsSelectedOutput else {
            chordStatus = "Choose Trackpad, enable dedicated MPE, or explicitly allow equal-tempered MIDI in Scale Editor."
            return
        }
        if selected.sendsHaptics {
            guard (!touchBarOwnsHaptics || sharedNoteOutputEnabled), !speakerBusy, !touchRunning, !midiHelperRunning, !midiRunning,
                  !isPlaying, !sequenceOwnsHaptics, !liveHingeEnabled, !captureArmed, !pointerCaptured else {
                chordStatus = "Stop other haptic performances and the MIDI bridge first, or choose MIDI only."
                return
            }
            cancelStartupGreeting()
            renderGeneration &+= 1
            playback?.stop(closeDriver: false)
            guard requireEngine(), let driver else {
                chordStatus = "Force Touch output unavailable. MIDI-only mode remains available."
                return
            }
            chordHaptics = makeLiveNoteOutput(driver: driver, source: .chords)
        }
        do {
            chordMPEActive = chordBank.usesMPE
            if selected.sendsMIDI {
                try activeChordMIDIOutput.open()
                if chordMPEActive {
                    for command in ChordMPEState.configuration() {
                        guard activeChordMIDIOutput.send(command) else {
                            throw ChordMPEConfigurationError.delivery
                        }
                    }
                }
            }
            if selected.sendsHaptics {
                let token = UUID()
                chordHapticToken = token
                try chordHaptics?.start { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.chordHapticToken == token else { return }
                        self.disarmChordPads()
                        self.chordStatus = "Trackpad output failed: " + message
                    }
                }
            }
            chordArmed = true
            chordStatus = selected.rawValue + (selected.sendsHaptics && sharedNoteOutputEnabled ? " ready (shared experimental)" : " ready")
            if chordMPEActive {
                chordStatus += " · dedicated MPE"
            } else if chordBank.customScale?.isMicrotonal == true && selected.sendsMIDI {
                chordStatus += " · MIDI 12-TET approximation"
            }
        } catch {
            chordHapticToken = nil
            chordHaptics?.stop()
            chordHaptics = nil
            releaseSharedOutputIfIdle()
            chordStatus = error.localizedDescription
        }
    }

    private static func readChordProgression() -> ChordProgression {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.chordProgression.v1"),
              let archive = try? WorkspaceArchive.decode(ChordProgression.self, from: data),
              archive.payload.isValid else { return ChordProgression() }
        return archive.payload
    }

    func updateChordProgression(_ proposed: ChordProgression) {
        guard !progressionRunning, proposed.isValid else { return }
        chordProgression = proposed
        if let data = try? WorkspaceArchive.encode(name: "Chord progression", payload: proposed) {
            UserDefaults.standard.set(data, forKey: "TIHULU.chordProgression.v1")
        }
    }

    func startChordProgression(singleSlot: Int? = nil) {
        var settings = chordProgression
        if let singleSlot {
            guard settings.arpeggio != nil, (0..<ChordBank.padCount).contains(singleSlot) else { return }
            settings.slots = [singleSlot]
        }
        guard chordArmed, !progressionRunning,
              let plan = settings.plan(bank: chordBank, bpm: bpm) else {
            chordStatus = "Arm output and choose a valid non-empty progression and tempo."
            return
        }
        releaseChordPads()
        guard chordArmed else { return }
        let token = UUID()
        progressionToken = token
        progressionRunning = true
        progressionSingleSlot = singleSlot
        progressionTask = Task { [weak self] in
            let clock = ContinuousClock()
            let period = Duration.nanoseconds(Int64((plan.duration * 1_000_000_000).rounded()))
            var origin = clock.now
            do {
                repeat {
                    for step in plan.steps {
                        let onset = origin.advanced(by: .nanoseconds(Int64((step.onset * 1_000_000_000).rounded())))
                        let end = onset.advanced(by: .nanoseconds(Int64((step.gate * 1_000_000_000).rounded())))
                        try await clock.sleep(until: onset)
                        guard !Task.isCancelled, self?.progressionToken == token,
                              self?.chordArmed == true else { return }
                        if self?.progressionStep != step.position { self?.progressionStep = step.position }
                        // Skip an expired gate instead of bursting missed notes.
                        guard let slot = step.slot, let pad = step.pad, clock.now < end else { continue }
                        guard self?.pressProgressionChord(slot: slot, pad: pad, plan: plan) == true else { return }
                        try await clock.sleep(until: end)
                        guard !Task.isCancelled, self?.progressionToken == token else { return }
                        self?.releaseChordPad(slot)
                        guard self?.progressionToken == token else { return }
                    }
                    let boundary = origin.advanced(by: period)
                    try await clock.sleep(until: boundary)
                    guard !Task.isCancelled, self?.progressionToken == token else { return }
                    origin = clock.now >= boundary.advanced(by: period) ? clock.now : boundary
                } while plan.loop
                self?.stopChordProgression()
            } catch {
                if self?.progressionToken == token { self?.stopChordProgression() }
            }
        }
    }

    private func pressProgressionChord(slot: Int, pad: ChordPad, plan: ChordProgressionPlan) -> Bool {
        guard chordArmed, progressionRunning else { return false }
        let commands = chordState.press(slot: slot, pad: pad, channel: plan.channel, velocity: plan.velocity)
        guard deliverChordCommands(commands) else { return false }
        chordActiveSlots = chordState.activeSlots
        updateChordHaptics()
        return true
    }

    func stopChordProgression() {
        guard progressionRunning else { return }
        releaseChordPads()
    }

    func releaseManualChordPadsOnDisappear() {
        // A deliberately started progression can accompany a different
        // instrument page; global focus loss still invokes Release All.
        if !progressionRunning { releaseChordPads() }
    }

    func triggerChordPad(_ slot: Int) {
        guard chordArmed, let pad = chordBank.pad(at: slot) else { return }
        if progressionRunning { stopChordProgression() }
        guard chordArmed else { return }
        if chordState.activeSlots.contains(slot) {
            releaseChordPad(slot)
            if chordBank.latch || !chordArmed { return }
        }
        let commands = chordState.press(slot: slot, pad: pad, channel: chordBank.channel - 1,
                                        velocity: chordBank.velocity)
        guard deliverChordCommands(commands) else { return }
        chordActiveSlots = chordState.activeSlots
        updateChordHaptics()
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
        updateChordHaptics()
    }

    private func updateChordHaptics() {
        guard chordOwnsHaptics else { return }
        let frame = NoteHapticRenderer.frame(notes: chordState.activeNotes, velocity: chordBank.velocity,
                                              centsByPitchClass: chordBank.centsByPitchClass)
        chordHaptics?.update(frame: frame, masterLevel: masterLevel)
    }

    private func deliverChordCommands(_ commands: [SensorCommand]) -> Bool {
        guard chordBank.effectiveOutput.sendsMIDI else { return true }
        for logical in commands {
            let routed: [SensorCommand]
            if chordMPEActive {
                guard let next = chordMPEState.route(logical, centsByPitchClass: chordBank.centsByPitchClass) else {
                    disarmChordPads()
                    chordStatus = "MPE note limit or invalid tuning. Output stopped; check the DAW."
                    return false
                }
                routed = next
            } else {
                routed = [logical]
            }
            for command in routed {
                let isNote = command.destination.kind == .note
                if isNote && command.value > 0 { chordOutstanding.insert(command.destination) }
                guard activeChordMIDIOutput.send(command) else {
                    disarmChordPads()
                    chordStatus = "MIDI delivery failed. Check the DAW; note release is not confirmed."
                    return false
                }
                if isNote && command.value == 0 { chordOutstanding.remove(command.destination) }
            }
        }
        return true
    }

    func releaseChordPads() {
        progressionToken = nil
        progressionTask?.cancel()
        progressionTask = nil
        progressionRunning = false
        progressionStep = nil
        progressionSingleSlot = nil
        for task in chordTimers.values { task.cancel() }
        chordTimers.removeAll()
        chordTimerTokens.removeAll()
        _ = chordState.releaseAll()
        chordActiveSlots = []
        chordHaptics?.update(frame: nil, masterLevel: 0)
        // Retry all possibly transmitted notes, including a failed Note On.
        for key in Array(chordOutstanding) {
            if activeChordMIDIOutput.send(.init(key, value: 0)) { chordOutstanding.remove(key) }
        }
        if chordOutstanding.isEmpty { chordMPEState.clearAfterRelease() }
        if !chordOutstanding.isEmpty {
            chordHapticToken = nil
            chordHaptics?.stop()
            chordHaptics = nil
            releaseSharedOutputIfIdle()
            chordArmed = false
            chordStatus = "Some MIDI releases failed. Reset the receiving DAW and retry Release All."
        }
    }

    func disarmChordPads() {
        chordHapticToken = nil
        chordHaptics?.stop()
        chordHaptics = nil
        releaseSharedOutputIfIdle()
        releaseChordPads()
        chordArmed = false
        if chordOutstanding.isEmpty { chordStatus = "Output off" }
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
        disarmTouchBarOutput()
        if touchBarProfile.zones.contains(.chords) && !next.zones.contains(.chords) {
            releaseChordPads()
        }
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
        nativePianoTokens.removeAll()
        releaseOptionalTouchBarNotes()
        for note in heldTouchBarNotes {
            midi?.sendPerformanceNote(
                note: note, velocity: 0, isOn: false, channel: touchBarProfile.channel
            )
        }
        heldTouchBarNotes.removeAll()
    }

    func touchBarKey(_ note: Int, pressed: Bool, owner: TouchBarNoteOwner = .screenPiano) {
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed else { return }
            let commands = touchBarLocalState.key(note, owner: owner, pressed: pressed,
                channel: touchBarProfile.channel, velocity: touchBarProfile.noteVelocity)
            if deliverTouchBarCommands(commands) { updateTouchBarHaptics() }
            return
        }
        cancelStartupGreeting()
        if !midiRunning && pressed { startMIDI() }
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
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed, value.isFinite else { return }
            let safe = min(1, max(0, value))
            let channel = touchBarProfile.channel
            var commands: [SensorCommand] = []
            switch zone {
            case .pitchBend, .fretless:
                touchBarLocalState.setBend(safe)
                commands = [.init(.init(.pitchBend, channel: channel), value: Int((safe * 16383).rounded()))]
            case .expression:
                touchBarLocalState.setExpression(safe)
                commands = [.init(.init(.controlChange, channel: channel, number: 11), value: Int((safe * 127).rounded()))]
            case .vibrato, .filter:
                commands = [.init(.init(.controlChange, channel: channel, number: zone == .vibrato ? 1 : 74), value: Int((safe * 127).rounded()))]
            case .keys, .chords, .sustain: break
            }
            if deliverTouchBarCommands(commands) { updateTouchBarHaptics() }
            return
        }
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
        case .keys, .chords, .sustain:
            break
        }
    }

    func touchBarSustainPressed(_ isPressed: Bool) {
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed else { return }
            let next = touchBarProfile.sustainMode == .toggle
                ? (isPressed ? !touchBarLocalState.sustain : touchBarLocalState.sustain) : isPressed
            let commands = touchBarLocalState.setSustain(next, channel: touchBarProfile.channel,
                                                          velocity: touchBarProfile.noteVelocity)
            touchBarSustainOn = touchBarLocalState.sustain
            if deliverTouchBarCommands(commands) { updateTouchBarHaptics() }
            return
        }
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

    func touchBarNativeTap(_ note: Int) {
        guard !touchBarProfile.effectiveOutput.sendsHaptics || touchBarOutputArmed else { return }
        let token = UUID()
        nativePianoTokens[note] = token
        touchBarKey(note, pressed: true, owner: .nativePiano)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, self.nativePianoTokens[note] == token else { return }
            self.nativePianoTokens.removeValue(forKey: note)
            self.touchBarKey(note, pressed: false, owner: .nativePiano)
        }
    }

    func armTouchBarOutput() {
        guard touchBarProfile.effectiveOutput.sendsHaptics, !touchBarOutputArmed else { return }
        guard (!chordOwnsHaptics || sharedNoteOutputEnabled), !speakerBusy, !touchRunning, !midiHelperRunning, !midiRunning,
              !isPlaying, !sequenceOwnsHaptics, !liveHingeEnabled, !captureArmed, !pointerCaptured else {
            touchBarOutputStatus = "Stop other haptic sessions and the MIDI bridge first."
            return
        }
        releaseOptionalTouchBarNotes()
        guard touchBarOutstanding.isEmpty else {
            touchBarOutputStatus = "MIDI release failed. Reset the DAW and retry."
            return
        }
        cancelStartupGreeting()
        renderGeneration &+= 1
        playback?.stop(closeDriver: false)
        guard requireEngine(), let driver else {
            touchBarOutputStatus = "Force Touch output unavailable."
            return
        }
        do {
            if touchBarProfile.effectiveOutput.sendsMIDI {
                try touchBarDedicatedMIDI.open()
                let channel = touchBarProfile.channel
                // Dedicated endpoint: set the same +/-12-semitone bend range as local sound.
                for (cc, value) in [(101,0),(100,0),(6,12),(38,0),(101,127),(100,127)] {
                    guard touchBarDedicatedMIDI.send(.init(.init(.controlChange, channel: channel, number: cc), value: value)) else {
                        touchBarOutputStatus = "Unable to configure dedicated MIDI output."
                        return
                    }
                }
            }
            let output = makeLiveNoteOutput(driver: driver, source: .touchBar)
            touchBarHaptics = output
            let token = UUID()
            touchBarOutputToken = token
            try output.start { [weak self] message in
                Task { @MainActor in
                    guard let self, self.touchBarOutputToken == token else { return }
                    self.disarmTouchBarOutput()
                    self.touchBarOutputStatus = "Trackpad output failed: " + message
                }
            }
            touchBarOutputArmed = true
            touchBarOutputStatus = touchBarProfile.effectiveOutput.rawValue + (sharedNoteOutputEnabled ? " ready (shared experimental)" : " ready")
        } catch {
            touchBarOutputToken = nil
            touchBarHaptics?.stop()
            touchBarHaptics = nil
            releaseSharedOutputIfIdle()
            touchBarOutputStatus = error.localizedDescription
        }
    }

    private func updateTouchBarHaptics() {
        guard touchBarOutputArmed else { return }
        touchBarHaptics?.update(frame: touchBarLocalState.frame(velocity: touchBarProfile.noteVelocity),
                                masterLevel: masterLevel)
    }

    private func deliverTouchBarCommands(_ commands: [SensorCommand]) -> Bool {
        guard touchBarProfile.effectiveOutput.sendsMIDI else { return true }
        for command in commands {
            let isNote = command.destination.kind == .note
            if isNote && command.value > 0 { touchBarOutstanding.insert(command.destination) }
            guard touchBarDedicatedMIDI.send(command) else {
                disarmTouchBarOutput()
                touchBarOutputStatus = "MIDI delivery failed; check note release in the DAW."
                return false
            }
            if isNote && command.value == 0 { touchBarOutstanding.remove(command.destination) }
        }
        return true
    }

    func releaseOptionalTouchBarNotes() {
        // Do not invalidate legacy MIDI tap timers when merely releasing the
        // optional output. Otherwise an app-focus change could strand a note.
        guard touchBarProfile.effectiveOutput.sendsHaptics || touchBarOutputArmed ||
              !touchBarOutstanding.isEmpty else { return }
        nativePianoTokens.removeAll()
        let channel = touchBarProfile.channel
        _ = touchBarLocalState.reset(channel: channel)
        touchBarHaptics?.update(frame: nil, masterLevel: 0)
        if touchBarOutputArmed { touchBarSustainOn = false }
        for note in Array(touchBarOutstanding) {
            if touchBarDedicatedMIDI.send(.init(note, value: 0)) { touchBarOutstanding.remove(note) }
        }
        if touchBarOutputArmed && touchBarProfile.effectiveOutput.sendsMIDI {
            _ = touchBarDedicatedMIDI.send(.init(.init(.pitchBend, channel: channel), value: 8192))
            _ = touchBarDedicatedMIDI.send(.init(.init(.controlChange, channel: channel, number: 1), value: 0))
            _ = touchBarDedicatedMIDI.send(.init(.init(.controlChange, channel: channel, number: 11), value: 127))
        }
        if !touchBarOutstanding.isEmpty {
            touchBarOutputToken = nil
            touchBarHaptics?.stop()
            touchBarHaptics = nil
            releaseSharedOutputIfIdle()
            touchBarOutputArmed = false
            touchBarOutputStatus = "Some MIDI releases failed; reset the receiving DAW."
        }
    }

    func disarmTouchBarOutput() {
        touchBarOutputToken = nil
        touchBarHaptics?.stop()
        touchBarHaptics = nil
        releaseSharedOutputIfIdle()
        releaseOptionalTouchBarNotes()
        touchBarOutputArmed = false
        if touchBarOutstanding.isEmpty { touchBarOutputStatus = "Optional Trackpad output off" }
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

    private func prepareEngine() {
        guard !engineReady, !speakerBusy else { return }
        // Only initialize after the previous session has been retired.
        engineGeneration &+= 1
        let generation = engineGeneration
        captureMonitor?.stop()
        captureMonitor = nil
        driver?.close()
        playback = nil
        touch = nil
        midi = nil
        systemAudio = nil
        driver = nil
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
                    guard let self, self.engineGeneration == generation else { return }
                    self.pointerCaptured = captured
                    if self.captureArmed || self.touchRunning || self.midiHelperRunning {
                        self.captureStatus = captured
                            ? "Cursor captured · press the shortcut again or Esc"
                            : "Cursor free · event monitor active"
                    }
                }
            }
            capture.onPanic = { [weak self] in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    self.panicStop()
                }
            }
            capture.onPhysicalClick = { [weak self] down, pressure in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    self.handlePhysicalClick(down, pressure: pressure)
                }
            }
            capture.onPhysicalPressure = { [weak self] pressure in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    self.handlePhysicalPressure(pressure)
                }
            }
            capture.onMonitorRecovered = { [weak self] in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    self.pointerCaptured = false
                    // A click-up event may have been lost while the tap timed out.
                    // Release any synthetic sustain state instead of sticking CC64.
                    self.handlePhysicalClick(false, pressure: 0)
                    self.captureStatus = "Input monitor recovered after timeout · cursor released · press the capture shortcut to resume"
                }
            }
            capture.onMonitorFailed = { [weak self] in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
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
        stopLiveSequence()
        engineGeneration &+= 1
        disarmTouchBarOutput()
        disarmChordPads()
        sharedNoteOutput?.retire()
        sharedNoteOutput = nil
        sharedNoteOutputEnabled = false
        renderGeneration &+= 1
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
        playback?.stop(closeDriver: false)
        touch?.stopPreview()
        midi?.stop()
        // Terminal revocation drains an in-flight submission and blocks any
        // late producer or monitoring request on this exact driver instance.
        driver?.panicStop()
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
        // Reconnect is an explicit session reset, never a silent hot swap.
        // Preserve user settings, but do not auto-resume active performances.
        panicStop()
        let generation = engineGeneration
        if speakerBusy {
            let pending = speakerTask
            engineStatus = "Stopping capture before reconnect"
            Task { [weak self] in
                await pending?.value
                guard let self, self.engineGeneration == generation else { return }
                self.prepareEngine()
            }
        } else {
            prepareEngine()
        }
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
            let generation = self.renderGeneration
            engine.play(events: events, masterLevel: self.masterLevel) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.renderGeneration == generation else { return }
                    self.startupGreetingPlaying = false
                    self.startupGreetingTask = nil
                }
            }
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

    private func beginPlaybackRequest() -> UInt64 {
        renderGeneration &+= 1
        playback?.stop(closeDriver: false)
        isPlaying = true
        lastError = nil
        return renderGeneration
    }

    private func playRendered(_ events: [ScheduledHapticEvent], token: UInt64,
                              loop: Bool = false, duration: Double? = nil, level: Double? = nil) {
        guard renderGeneration == token, let playback else {
            if renderGeneration == token { isPlaying = false }
            return
        }
        playback.play(events: events, masterLevel: level ?? masterLevel,
                      loop: loop, duration: duration) { [weak self] error in
            Task { @MainActor in
                guard let self, self.renderGeneration == token else { return }
                self.isPlaying = false
                if let error {
                    self.lastError = error
                    self.engineStatus = "Playback error"
                }
            }
        }
    }

    func speak(_ text: String, voice: String?) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = beginPlaybackRequest()
        let renderText = text
        let renderVoice = voice
        Task {
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try VoiceHapticService.render(text: renderText, voice: renderVoice)
                }.value
                guard renderGeneration == token, !liveNoteOwnsHaptics else { return }
                playRendered(events, token: token)
            } catch {
                guard renderGeneration == token else { return }
                fail(error)
            }
        }
    }

    /// One independent MIDI sequence, with optional exclusive haptic
    /// preview. MIDI-only does not require the Force Touch driver.
    func startLiveSequence(output: MusicalOutput, loop: Bool, makeClip: () throws -> MIDIClip) {
        guard output.sendsMIDI, !sequenceRunning else { return }
        do {
            let clip = try makeClip().validated()
            let schedule = try MIDIClipSchedule(clip)
            let hapticEvents = output.sendsHaptics ? try clip.grooveHapticEvents() : []
            if output.sendsHaptics {
                guard allowOtherPerformance(), !isPlaying, !touchRunning, !midiRunning,
                      !midiHelperRunning, !liveHingeEnabled else {
                    sequenceStatus = "Stop other haptic performances before choosing Both."
                    return
                }
                cancelStartupGreeting()
                guard requireEngine(), playback != nil else { return }
            }
            guard sequenceLedger.releaseAll(send: { sequenceMIDI.send($0) }) else {
                sequenceStatus = "MIDI release failed. Reset the receiving DAW and retry Stop."
                return
            }
            try sequenceMIDI.open()
            let token = UUID()
            sequenceToken = token
            sequenceRunning = true
            sequenceOwnsHaptics = output.sendsHaptics
            sequenceStatus = "Playing · TIHULU Sequencer · " + output.rawValue
            if output.sendsHaptics {
                renderGeneration &+= 1
                isPlaying = true
                playback?.play(events: hapticEvents, masterLevel: masterLevel, loop: loop,
                               duration: schedule.seconds(at: schedule.length)) { [weak self] error in
                    if let error {
                        Task { @MainActor in
                            guard let self, self.sequenceToken == token else { return }
                            self.stopLiveSequence()
                            self.lastError = error
                        }
                    }
                }
            }
            sequenceTask = Task { [weak self] in
                let clock = ContinuousClock()
                func offset(_ tick: Int) -> Duration {
                    .nanoseconds(Int64((schedule.seconds(at: tick) * 1_000_000_000).rounded()))
                }
                let period = offset(schedule.length)
                var origin = clock.now
                do {
                    repeat {
                        for event in schedule.events {
                            try await clock.sleep(until: origin.advanced(by: offset(event.tick)))
                            guard !Task.isCancelled, let self, self.sequenceToken == token else { return }
                            // Skip notes whose entire gate has expired.
                            if event.isNoteOn && clock.now >= origin.advanced(by: offset(event.endTick)) { continue }
                            let delivered = self.sequenceLedger.deliver(event.command, send: { self.sequenceMIDI.send($0) })
                            guard delivered else {
                                self.stopLiveSequence()
                                self.lastError = "Sequencer MIDI delivery failed. Check the receiving DAW."
                                return
                            }
                        }
                        let boundary = origin.advanced(by: period)
                        try await clock.sleep(until: boundary)
                        guard !Task.isCancelled, self?.sequenceToken == token else { return }
                        // When substantially stalled, never burst old cycles.
                        origin = clock.now >= boundary.advanced(by: period) ? clock.now : boundary
                    } while loop
                    self?.stopLiveSequence()
                } catch {
                    if self?.sequenceToken == token { self?.stopLiveSequence() }
                }
            }
        } catch {
            sequenceStatus = error.localizedDescription
        }
    }

    func stopLiveSequence() {
        sequenceToken = nil
        sequenceTask?.cancel()
        sequenceTask = nil
        if sequenceOwnsHaptics {
            renderGeneration &+= 1
            playback?.stop(closeDriver: false)
            isPlaying = false
        }
        sequenceOwnsHaptics = false
        sequenceRunning = false
        let released = sequenceLedger.releaseAll(send: { sequenceMIDI.send($0) })
        sequenceStatus = released ? "Sequencer MIDI idle" : "MIDI release failed. Reset the receiving DAW and retry Stop."
    }

    func playGrooveClip(loop: Bool, makeClip: () throws -> MIDIClip) {
        guard allowOtherPerformance() else { return }
        guard !touchRunning, !midiRunning, !midiHelperRunning, !liveHingeEnabled else {
            lastError = "Stop other live performances before starting groove haptic playback."
            return
        }
        do {
            let clip = try makeClip()
            let events = try clip.grooveHapticEvents()
            cancelStartupGreeting()
            guard requireEngine() else { return }
            let token = beginPlaybackRequest()
            playRendered(events, token: token, loop: loop,
                         duration: Double(clip.length) * 60 / clip.bpm / Double(MIDIClip.ppq))
        } catch {
            // Validation before taking over the current playback.
            lastError = error.localizedDescription
        }
    }

    func playNotes(_ steps: [NoteStep], length: Int = 16, loop: Bool = false) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard let duration = PlaybackTimeline.patternDuration(bpm: bpm, stepsPerBeat: 4, length: length) else {
            lastError = "Invalid sequence tempo or length."
            return
        }
        let token = beginPlaybackRequest()
        do {
            let events = try HapticPatternRenderer.notes(.init(bpm: bpm, stepsPerBeat: 4, length: length, steps: steps))
            playRendered(events, token: token, loop: loop, duration: duration)
        } catch { fail(error) }
    }

    func playDrums(_ hits: [DrumStep], length: Int = 16, loop: Bool = false) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard let duration = PlaybackTimeline.patternDuration(bpm: bpm, stepsPerBeat: 4, length: length) else {
            lastError = "Invalid sequence tempo or length."
            return
        }
        let token = beginPlaybackRequest()
        let events = HapticPatternRenderer.drums(.init(bpm: bpm, stepsPerBeat: 4, length: length, hits: hits))
        playRendered(events, token: token, loop: loop, duration: duration)
    }

    func stopPlayback() {
        stopLiveSequence()
        renderGeneration &+= 1
        cancelStartupGreeting()
        playback?.stop(closeDriver: false)
        isPlaying = false
    }

    func testTone(frequency: Double) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard frequency.isFinite, frequency > 0 else { return }
        let duration = max(2, (0.04 * frequency).rounded()) / frequency * 1_000
        let token = beginPlaybackRequest()
        playRendered([.init(time: 0, frame: .init(tones: [.init(frequencyHz: frequency)],
                       durationMS: duration, level: masterLevel))], token: token, level: 1)
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
        let token = beginPlaybackRequest()
        playRendered(events, token: token, level: 1)
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
            let generation = engineGeneration
            try touch.startPreview(configuration: monitoringConfiguration) { [weak self] states in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation, self.touchPreviewRunning else { return }
                    self.handleSharedSurfaceStates(states)
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

    /// Explicitly copy the current bank scale. Live performances never retune
    /// as a side effect of editing the bank on another page.
    func useChordBankScaleForTouch() {
        guard !touchRunning else { return }
        var scale = chordBank.customScale ?? CustomScale()
        if chordBank.customScale == nil {
            scale.name = chordBank.scale.rawValue
            scale.intervals = chordBank.scale.intervals
        }
        guard scale.isValid else { return }
        touchCustomScale = scale
    }

    func clearTouchCustomScale() {
        guard !touchRunning else { return }
        touchCustomScale = nil
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
        guard configuration.permitsMelodicMIDI else {
            lastError = "Custom cent offsets require Trackpad output or explicit equal-tempered MIDI approximation in the Scale Editor. Drum MIDI is unaffected."
            return
        }
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
            let generation = engineGeneration
            try midi.start(masterLevel: masterLevel) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation, self.midiRunning else { return }
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
        if !touchBarProfile.effectiveOutput.sendsHaptics {
            releaseTouchBarNotes()
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
        let token = beginPlaybackRequest()
        do {
            let data = try Data(contentsOf: url)
            let midi = try MIDIFileParser.parse(data)
            currentFileName = url.lastPathComponent
            playRendered(MIDIFileParser.hapticEvents(from: midi), token: token,
                         duration: midi.durationSeconds)
        } catch { fail(error) }
    }

    func playAudioFile(_ url: URL, profile: AudioHapticProfile? = nil) {
        guard allowOtherPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        currentFileName = url.lastPathComponent
        let selectedProfile = profile ?? activeProfile
        let fileURL = url
        let token = beginPlaybackRequest()
        Task {
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try AudioFileHapticService.render(url: fileURL, profile: selectedProfile)
                }.value
                guard renderGeneration == token, !liveNoteOwnsHaptics else { return }
                playRendered(events, token: token)
            } catch {
                guard renderGeneration == token else { return }
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
        guard !liveNoteOwnsHaptics, !sequenceOwnsHaptics else {
            lastError = "Disarm the optional Trackpad note output before starting Speaker."
            return
        }
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
        guard !sequenceOwnsHaptics else {
            lastError = "Stop the sequencer's combined Trackpad/MIDI output first."
            return false
        }
        guard !liveNoteOwnsHaptics else {
            lastError = "Disarm the optional Trackpad note output before starting another haptic performance."
            return false
        }
        guard !speakerBusy else {
            lastError = "Stop Trackpad Speaker before using another haptic or MIDI performance."
            return false
        }
        return true
    }

    private func requireEngine() -> Bool {
        if engineReady { return true }
        guard !speakerBusy else {
            lastError = "Wait for system audio capture to finish stopping."
            return false
        }
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
