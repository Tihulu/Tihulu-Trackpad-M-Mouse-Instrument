#if os(macOS)
import Foundation
import CoreMIDI
import NoSpeakerCore

public struct LiveMIDIMessage: Sendable, Equatable {
    public var channel: Int
    public var note: Int
    public var velocity: Int
    public var isNoteOn: Bool
}

public enum TouchMIDIMode: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard MIDI"
    case mpe = "MPE"

    public var id: String { rawValue }
}

public enum MIDIHelperMode: String, CaseIterable, Identifiable, Sendable {
    case vibrato = "Vibrato"
    case pitchBend = "Pitch Bend"
    case expression = "Expression"
    case hybrid = "Hybrid"

    public var id: String { rawValue }
}

public enum MIDIHapticError: LocalizedError {
    case client(OSStatus)
    case destination(OSStatus)
    case source(OSStatus)
    case inputPort(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .client(let status):
            if status == -2 {
                return "CoreMIDI lost its MIDIServer connection (OSStatus -2). Restart the instrument app. The MIDI client will now be kept alive across mode switches to prevent recurrence."
            }
            return "CoreMIDI client creation failed (OSStatus \(status))."
        case .destination(let status): return "CoreMIDI virtual input creation failed (OSStatus \(status))."
        case .source(let status): return "CoreMIDI virtual output creation failed (OSStatus \(status))."
        case .inputPort(let status): return "CoreMIDI input port creation failed (OSStatus \(status))."
        }
    }
}

/// CoreMIDI's on-demand MIDIServer may tear down its IPC channel when the
/// process disposes its last MIDI client. After that, subsequent creation can
/// return OSStatus -2 until process restart. Keep exactly one client alive for
/// the lifetime of the app, including across MIDI mode switches and reconnects.
private final class MIDIProcessClient: @unchecked Sendable {
    static let shared = MIDIProcessClient()
    private let lock = NSLock()
    private var retainedClient = MIDIClientRef()

    func acquire() throws -> MIDIClientRef {
        lock.lock()
        defer { lock.unlock() }
        if retainedClient != 0 { return retainedClient }
        var newClient = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(
            "Tihulu Trackpad & M. Mouse Instrument" as CFString, &newClient
        ) { _ in }
        guard status == noErr else { throw MIDIHapticError.client(status) }
        retainedClient = newClient
        return newClient
    }

    // Deliberately not disposed while this process lives. CoreMIDI automatically
    // releases the client at process exit; mode stops only dispose endpoints.
}

/// Bidirectional CoreMIDI bridge for Logic Pro and other DAWs.
///
/// - "NoSpeaker Haptic MIDI In": DAW/controller -> NoSpeaker haptic playback.
/// - "NoSpeaker Touch MIDI Out": Touch Instrument -> DAW software instrument.
///
/// Incoming notes remain active until their matching note-off arrives. CC64 sustain
/// holds released notes until the pedal is lifted. Pitch bend is applied continuously.
public final class MIDIHapticService: @unchecked Sendable {
    private struct NoteKey: Hashable {
        let channel: Int
        let note: Int
    }

    private struct ActiveNote {
        var velocity: Int
        var keyDownCount: Int
        var releasedWhileSustained: Bool
    }

    private struct TouchKey: Hashable {
        let surface: TouchSurfaceKind
        let id: Int
    }

    private struct OutgoingTouch {
        var note: Int
        var channel: Int
        var fretless: Bool
    }

    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.tihulu.nospeaker.midi-render", qos: .userInteractive)

    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()
    private var virtualSource = MIDIEndpointRef()
    private var inputPort = MIDIPortRef()

    private var masterLevel = 0.8
    private var enabled = false
    private var callback: (@Sendable (LiveMIDIMessage) -> Void)?

    private var activeNotes: [NoteKey: ActiveNote] = [:]
    private var sustainByChannel: [Int: Bool] = [:]
    private var pitchBendByChannel: [Int: Int] = [:]
    private var pitchBendRangeByChannel: [Int: Double] = [:]
    private var rpnMSBByChannel: [Int: Int] = [:]
    private var rpnLSBByChannel: [Int: Int] = [:]
    private var bendRangeSemitonesByChannel: [Int: Int] = [:]
    private var bendRangeCentsByChannel: [Int: Int] = [:]
    private var modulationByChannel: [Int: Int] = [:]
    private var volumeByChannel: [Int: Int] = [:]
    private var expressionByChannel: [Int: Int] = [:]
    private var channelPressureByChannel: [Int: Int] = [:]
    private var renderTimer: DispatchSourceTimer?
    private var inputHapticsEnabled = true

    private var outgoingTouches: [TouchKey: OutgoingTouch] = [:]
    private var touchOutputNote: Int?
    private var touchOutputChannel = 0
    private var touchOutputFretless = false

    // The Helper owns CC64 only while it is active. Do not send repeated
    // CC64 messages per frame or leave a sustain latch behind on Stop/Panic.
    private var helperSustainChannel: Int?
    private var helperSustainOn = false
    private var touchSustainChannels: Set<Int> = []

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    deinit {
        stop()
        disposeEndpoints()
    }

    public func start(masterLevel: Double, onMessage: (@Sendable (LiveMIDIMessage) -> Void)? = nil) throws {
        lock.lock()
        let alreadyActive = enabled && destination != 0 && virtualSource != 0 && inputPort != 0
        self.masterLevel = masterLevel
        self.callback = onMessage
        self.inputHapticsEnabled = true
        lock.unlock()
        if alreadyActive { return }

        // Soft-stop note/controller state without closing the virtual MIDI
        // endpoints. Logic retains the same endpoints across mode switches.
        stop()
        if client == 0 { client = try MIDIProcessClient.shared.acquire() }
        if destination == 0 || virtualSource == 0 || inputPort == 0 {
            // Clean up any partial endpoints left by a previous failed start,
            // while keeping the process-wide CoreMIDI client alive.
            disposeEndpoints()
            try createEndpoints()
        }

        lock.lock()
        enabled = true
        activeNotes.removeAll()
        sustainByChannel.removeAll()
        pitchBendByChannel.removeAll()
        pitchBendRangeByChannel.removeAll()
        rpnMSBByChannel.removeAll()
        rpnLSBByChannel.removeAll()
        bendRangeSemitonesByChannel.removeAll()
        bendRangeCentsByChannel.removeAll()
        modulationByChannel.removeAll()
        volumeByChannel.removeAll()
        expressionByChannel.removeAll()
        channelPressureByChannel.removeAll()
        outgoingTouches.removeAll()
        helperSustainOn = false
        helperSustainChannel = nil
        touchSustainChannels.removeAll()
        lock.unlock()
        startRenderTimer()
    }

    private func createEndpoints() throws {
        var status: OSStatus = noErr
        var newDestination = MIDIEndpointRef()
        status = MIDIDestinationCreateWithProtocol(
            client,
            "NoSpeaker Haptic MIDI In" as CFString,
            ._1_0,
            &newDestination
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else { stop(); throw MIDIHapticError.destination(status) }
        destination = newDestination

        var newSource = MIDIEndpointRef()
        status = MIDISourceCreate(client, "NoSpeaker Touch MIDI Out" as CFString, &newSource)
        guard status == noErr else { stop(); throw MIDIHapticError.source(status) }
        virtualSource = newSource

        var newInput = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(
            client,
            "NoSpeaker MIDI Input Port" as CFString,
            ._1_0,
            &newInput
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else { stop(); throw MIDIHapticError.inputPort(status) }
        inputPort = newInput

        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            if source != 0, source != virtualSource {
                MIDIPortConnectSource(inputPort, source, nil)
            }
        }

    }

    public func stop() {
        releaseHelperSustain()
        releaseTouchSustain()
        endAllTouchOutput()

        lock.lock()
        enabled = false
        activeNotes.removeAll()
        sustainByChannel.removeAll()
        pitchBendByChannel.removeAll()
        pitchBendRangeByChannel.removeAll()
        rpnMSBByChannel.removeAll()
        rpnLSBByChannel.removeAll()
        bendRangeSemitonesByChannel.removeAll()
        bendRangeCentsByChannel.removeAll()
        modulationByChannel.removeAll()
        volumeByChannel.removeAll()
        expressionByChannel.removeAll()
        channelPressureByChannel.removeAll()
        outgoingTouches.removeAll()
        helperSustainOn = false
        helperSustainChannel = nil
        touchSustainChannels.removeAll()
        lock.unlock()

        renderTimer?.cancel()
        renderTimer = nil

        // Intentionally retain the virtual MIDI graph until the service is
        // destroyed. Teardown here would disconnect Logic on each mode switch.
    }

    private func disposeEndpoints() {
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource); virtualSource = 0 }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        // The shared process MIDI client is never disposed by a mode.
    }

    public func setInputHapticsEnabled(_ enabled: Bool) {
        lock.lock()
        inputHapticsEnabled = enabled
        lock.unlock()
    }

    public func sendTouchStates(
        _ states: [TouchPerformanceState],
        configuration: TouchInstrumentConfiguration,
        midiMode: TouchMIDIMode,
        baseChannel: Int = 0,
        multiTouchEnabled: Bool = true
    ) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }

        // GM percussion is always MIDI Channel 10 (zero-based 9). Pitched notes
        // stay on the requested channel, except channel 10 is reserved whenever
        // a drum surface is configured at the same time.
        let anyDrums = configuration.selectedSurfaces.contains {
            configuration.instrument(for: $0) == .drums &&
            configuration.output(for: $0).sendsMIDI
        }
        let selectedBase = max(0, min(15, baseChannel))
        let safeMelodicChannel = anyDrums && selectedBase == GMDrumPads.midiChannel
            ? 0 : selectedBase

        var desired = states.filter {
            $0.isDown && configuration.output(for: $0.surface).sendsMIDI
        }
        if !multiTouchEnabled {
            desired = Array(desired.prefix(1))
        }
        if configuration.fretless, midiMode == .standard {
            // Melodic fretless pitch bend is channel-wide in Standard MIDI.
            // Keep every percussion contact, but only one continuous-pitch
            // melodic finger; they are routed to separate channels.
            var keptMelodic = false
            desired = desired.filter { state in
                if configuration.instrument(for: state.surface) == .drums { return true }
                if keptMelodic { return false }
                keptMelodic = true
                return true
            }
        }

        let desiredKeys = Set(desired.map { TouchKey(surface: $0.surface, id: $0.contactID) })
        let releasedKeys = outgoingTouches.keys.filter { !desiredKeys.contains($0) }
        for key in releasedKeys {
            guard let outgoing = outgoingTouches.removeValue(forKey: key) else { continue }
            sendMIDI1(status: 0x80 | outgoing.channel, data1: outgoing.note, data2: 0)
            if outgoing.fretless {
                sendPitchBend(8192, channel: outgoing.channel)
            }
        }

        for state in desired {
            let key = TouchKey(surface: state.surface, id: state.contactID)
            let drums = configuration.instrument(for: state.surface) == .drums
            let isFretlessMelody = !drums && configuration.fretless
            let channel: Int

            if let existing = outgoingTouches[key] {
                channel = existing.channel
            } else if drums {
                channel = GMDrumPads.midiChannel
            } else if midiMode == .mpe {
                // Lower-zone MPE member channels, skipping the GM percussion
                // channel even when drum and pitched surfaces run together.
                let used = Set(outgoingTouches.values.map(\.channel))
                guard let free = (1...15).first(where: {
                    $0 != GMDrumPads.midiChannel && !used.contains($0)
                }) else { continue }
                channel = free
            } else {
                channel = safeMelodicChannel
            }

            if isFretlessMelody {
                let bendRange = max(1, min(24, Int(ceil(configuration.pitchSpanSemitones / 2.0))))
                let anchor = max(0, min(127,
                    configuration.baseMIDINote +
                    Int((configuration.pitchSpanSemitones / 2.0).rounded())
                ))

                if let existing = outgoingTouches[key] {
                    if existing.note != anchor || !existing.fretless {
                        sendMIDI1(status: 0x80 | existing.channel, data1: existing.note, data2: 0)
                        sendPitchBendRange(semitones: bendRange, channel: channel)
                        sendMIDI1(status: 0x90 | channel, data1: anchor, data2: state.velocity)
                        outgoingTouches[key] = .init(note: anchor, channel: channel, fretless: true)
                    }
                } else {
                    sendPitchBendRange(semitones: bendRange, channel: channel)
                    sendMIDI1(status: 0x90 | channel, data1: anchor, data2: state.velocity)
                    outgoingTouches[key] = .init(note: anchor, channel: channel, fretless: true)
                }

                let delta = max(-Double(bendRange),
                    min(Double(bendRange), state.continuousMIDI - Double(anchor)))
                let bend = Int((8192.0 + (delta / Double(bendRange)) * 8191.0).rounded())
                sendPitchBend(max(0, min(16383, bend)), channel: channel)
            } else {
                // Drums use actual GM note numbers (kick 36, snare 38, hats
                // 42/46 etc.). MIDI Channel 10 alone does not convert
                // pitched notes into drum pads.
                let note = max(0, min(127, state.quantizedMIDI))
                if let existing = outgoingTouches[key] {
                    if existing.note != note || existing.fretless {
                        sendMIDI1(status: 0x80 | existing.channel, data1: existing.note, data2: 0)
                        sendMIDI1(status: 0x90 | channel, data1: note, data2: state.velocity)
                        outgoingTouches[key] = .init(note: note, channel: channel, fretless: false)
                    }
                } else {
                    sendMIDI1(status: 0x90 | channel, data1: note, data2: state.velocity)
                    outgoingTouches[key] = .init(note: note, channel: channel, fretless: false)
                }
            }

            guard !drums else { continue }
            let vibrato = max(0, min(127, Int((state.vibrato * 127.0).rounded())))
            sendControlChange(controller: 1, value: vibrato, channel: channel)

            if configuration.pressureToExpression {
                sendControlChange(controller: 11, value: state.expression, channel: channel)
                if midiMode == .mpe {
                    sendChannelPressure(state.expression, channel: channel)
                }
            }
        }
    }

    public func endAllTouchOutput() {
        for (_, outgoing) in outgoingTouches {
            sendMIDI1(status: 0x80 | outgoing.channel, data1: outgoing.note, data2: 0)
            if outgoing.fretless {
                sendPitchBend(8192, channel: outgoing.channel)
            }
        }
        outgoingTouches.removeAll()
        endTouchOutput()
    }

    /// Sends CC64 only on state transitions. When the Helper channel changes,
    /// release sustain on the old channel before holding it on the new one.
    public func setHelperSustain(_ active: Bool, channel: Int) {
        let target = max(0, min(15, channel))

        lock.lock()
        let canSend = enabled && virtualSource != 0
        let previousChannel = helperSustainChannel
        let wasActive = helperSustainOn
        let changed = previousChannel != target
        helperSustainOn = active && canSend
        helperSustainChannel = active && canSend ? target : nil
        lock.unlock()

        guard canSend else { return }
        if wasActive, let old = previousChannel, (!active || changed) {
            sendControlChange(controller: 64, value: 0, channel: old)
        }
        if active && (!wasActive || changed) {
            sendControlChange(controller: 64, value: 127, channel: target)
        }
    }

    public func releaseHelperSustain() {
        lock.lock()
        let previousChannel = helperSustainChannel
        let wasActive = helperSustainOn
        let canSend = enabled && virtualSource != 0
        helperSustainOn = false
        helperSustainChannel = nil
        lock.unlock()

        if canSend, wasActive, let channel = previousChannel {
            sendControlChange(controller: 64, value: 0, channel: channel)
        }
    }

    /// CC64 output for Touch Instrument, independent from the MIDI Helper latch.
    /// Retains channels after finger lift so sustained MPE notes can be released.
    public func setTouchSustain(_ active: Bool, baseChannel: Int) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        let previous = touchSustainChannels
        let currentNoteChannels = Set(outgoingTouches.values.map(\.channel))
        let fallback = max(0, min(15, baseChannel))
        let targets = active && canSend
            ? previous.union(currentNoteChannels.isEmpty && previous.isEmpty
                ? Set([fallback]) : currentNoteChannels)
            : Set<Int>()
        touchSustainChannels = targets
        lock.unlock()

        guard canSend else { return }
        for channel in previous.subtracting(targets) {
            sendControlChange(controller: 64, value: 0, channel: channel)
        }
        for channel in targets.subtracting(previous) {
            sendControlChange(controller: 64, value: 127, channel: channel)
        }
    }

    public func releaseTouchSustain() {
        lock.lock()
        let channels = touchSustainChannels
        let canSend = enabled && virtualSource != 0
        touchSustainChannels.removeAll()
        lock.unlock()
        if canSend {
            for channel in channels {
                sendControlChange(controller: 64, value: 0, channel: channel)
            }
        }
    }

    public func sendHelperControls(
        x: Double,
        y: Double,
        contactSize: Double,
        assignments: MIDIHelperAssignments,
        channel: Int,
        pitchBendRange: Int,
        vibratoCC: Int,
        expressionCC: Int
    ) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }
        let safeChannel = max(0, min(15, channel))
        let safeX = min(1, max(0, x))
        let safeY = min(1, max(0, y))
        let safeSize = min(1, max(0, contactSize))

        if assignments.pitchBend {
            let normalized = (safeX - 0.5) * 2.0
            let bend = Int((8192 + normalized * 8191.0).rounded())
            sendPitchBendRange(semitones: max(1, min(24, pitchBendRange)), channel: safeChannel)
            sendPitchBend(max(0, min(16383, bend)), channel: safeChannel)
        }
        if assignments.vibrato {
            sendControlChange(
                controller: vibratoCC,
                value: Int((safeY * 127).rounded()),
                channel: safeChannel
            )
        }
        if assignments.expression {
            sendControlChange(
                controller: expressionCC,
                value: Int((safeSize * 127).rounded()),
                channel: safeChannel
            )
        }
    }

    public func resetHelperControls(
        assignments: MIDIHelperAssignments,
        channel: Int,
        vibratoCC: Int,
        expressionCC: Int
    ) {
        let safeChannel = max(0, min(15, channel))
        if assignments.pitchBend { sendPitchBend(8192, channel: safeChannel) }
        if assignments.vibrato { sendControlChange(controller: vibratoCC, value: 0, channel: safeChannel) }
        if assignments.expression { sendControlChange(controller: expressionCC, value: 127, channel: safeChannel) }
    }

    public func sendHelperGesture(
        x: Double,
        y: Double,
        pressure: Double,
        mode: MIDIHelperMode,
        channel: Int,
        pitchBendRange: Int,
        vibratoCC: Int = 1,
        expressionCC: Int = 11
    ) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }

        let safeChannel = max(0, min(15, channel))
        let safeX = min(1, max(0, x))
        let safeY = min(1, max(0, y))
        let safePressure = min(1, max(0, pressure))

        if mode == .pitchBend || mode == .hybrid {
            let normalized = (safeX - 0.5) * 2.0
            let bend = Int((8192.0 + normalized * 8191.0).rounded())
            sendPitchBendRange(semitones: max(1, min(24, pitchBendRange)), channel: safeChannel)
            sendPitchBend(max(0, min(16383, bend)), channel: safeChannel)
        }

        if mode == .vibrato || mode == .hybrid {
            sendControlChange(
                controller: max(0, min(127, vibratoCC)),
                value: Int((safeY * 127.0).rounded()),
                channel: safeChannel
            )
        }

        if mode == .expression || mode == .hybrid {
            sendControlChange(
                controller: max(0, min(127, expressionCC)),
                value: Int((safePressure * 127.0).rounded()),
                channel: safeChannel
            )
        }
    }

    public func resetHelperGesture(
        mode: MIDIHelperMode,
        channel: Int,
        vibratoCC: Int = 1,
        expressionCC: Int = 11
    ) {
        let safeChannel = max(0, min(15, channel))
        if mode == .pitchBend || mode == .hybrid {
            sendPitchBend(8192, channel: safeChannel)
        }
        if mode == .vibrato || mode == .hybrid {
            sendControlChange(controller: vibratoCC, value: 0, channel: safeChannel)
        }
        if mode == .expression || mode == .hybrid {
            sendControlChange(controller: expressionCC, value: 127, channel: safeChannel)
        }
    }

    public func sendControlChange(controller: Int, value: Int, channel: Int) {
        let cc = max(0, min(127, controller))
        let safeValue = max(0, min(127, value))
        let safeChannel = max(0, min(15, channel))
        sendMIDI1(status: 0xB0 | safeChannel, data1: cc, data2: safeValue)
    }

    /// Sends an explicit note from the Touch Bar or on-screen performance strip.
    /// A direct note-off (not zero-velocity note-on) is sent for every release.
    public func sendPerformanceNote(note: Int, velocity: Int, isOn: Bool, channel: Int) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }
        let safeNote = max(0, min(127, note))
        let safeVelocity = max(0, min(127, velocity))
        let safeChannel = max(0, min(15, channel))
        sendMIDI1(
            status: (isOn ? 0x90 : 0x80) | safeChannel,
            data1: safeNote,
            data2: isOn ? safeVelocity : 0
        )
    }

    public func sendChannelPressure(_ value: Int, channel: Int) {
        let safeValue = max(0, min(127, value))
        let safeChannel = max(0, min(15, channel))
        sendMIDI1(status: 0xD0 | safeChannel, data1: safeValue, data2: 0)
    }

    /// Sends Touch Instrument performance data to the DAW virtual MIDI output.
    ///
    /// Fretted mode emits ordinary note-on/note-off messages as the finger crosses
    /// scale zones. Fretless mode uses one center note plus +/-12-semitone pitch bend.
    public func sendTouch(
        continuousMIDI: Double,
        quantizedMIDI: Int,
        velocity: Int,
        isDown: Bool,
        fretless: Bool,
        rootMIDI: Int,
        channel: Int = 0
    ) {
        lock.lock()
        let active = enabled && virtualSource != 0
        lock.unlock()
        guard active else { return }

        let safeVelocity = max(1, min(127, velocity))
        let safeChannel = max(0, min(15, channel))

        if !isDown {
            endTouchOutput()
            return
        }

        if fretless {
            let centerNote = max(0, min(127, rootMIDI + 12))
            if touchOutputNote != centerNote || !touchOutputFretless || touchOutputChannel != safeChannel {
                endTouchOutput()
                touchOutputChannel = safeChannel
                touchOutputFretless = true
                sendPitchBendRange(semitones: 12, channel: safeChannel)
                sendMIDI1(status: 0x90 | safeChannel, data1: centerNote, data2: safeVelocity)
                touchOutputNote = centerNote
            }

            let deltaSemitones = max(-12.0, min(12.0, continuousMIDI - Double(centerNote)))
            let bend = Int((8192.0 + (deltaSemitones / 12.0) * 8191.0).rounded())
            sendPitchBend(max(0, min(16383, bend)), channel: safeChannel)
        } else {
            let note = max(0, min(127, quantizedMIDI))
            if touchOutputNote != note || touchOutputFretless || touchOutputChannel != safeChannel {
                endTouchOutput()
                touchOutputChannel = safeChannel
                touchOutputFretless = false
                sendMIDI1(status: 0x90 | safeChannel, data1: note, data2: safeVelocity)
                touchOutputNote = note
            }
        }
    }

    public func endTouchOutput() {
        guard let note = touchOutputNote else { return }
        sendMIDI1(status: 0x80 | touchOutputChannel, data1: note, data2: 0)
        if touchOutputFretless {
            sendPitchBend(8192, channel: touchOutputChannel)
        }
        touchOutputNote = nil
        touchOutputFretless = false
    }

    private func startRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        // Match Touch Instrument's continuously refreshed feel instead of behaving like
        // isolated haptic taps. A short overlapping frame prevents audible gaps while a
        // MIDI key (or sustain pedal) remains logically active.
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.renderActiveNotes() }
        renderTimer = timer
        timer.resume()
    }

    private func renderActiveNotes() {
        lock.lock()
        let active = enabled
        let hapticsEnabled = inputHapticsEnabled
        let notes = Array(activeNotes.prefix(6))
        let bends = pitchBendByChannel
        let bendRanges = pitchBendRangeByChannel
        let modulation = modulationByChannel
        let volumes = volumeByChannel
        let expressions = expressionByChannel
        let pressures = channelPressureByChannel
        let levelScale = masterLevel
        lock.unlock()
        guard active, hapticsEnabled, !notes.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var tones: [HapticTone] = []
        var combinedLevel = 0.0

        for (key, state) in notes {
            guard let frequency = try? MusicTheory.frequency(midi: key.note) else { continue }

            let bend14 = bends[key.channel] ?? 8192
            let bendRange = bendRanges[key.channel] ?? 2.0
            let bendNormalized = (Double(bend14) - 8192.0) / 8192.0
            let bendSemitones = bendNormalized * bendRange

            let modValue = Double(modulation[key.channel] ?? 0) / 127.0
            let pressureValue = Double(pressures[key.channel] ?? 0) / 127.0
            let vibratoDepthSemitones = 0.75 * max(modValue, pressureValue * 0.6)
            let vibrato = vibratoDepthSemitones * sin(now * 5.5 * 2.0 * Double.pi)

            let bentFrequency = frequency * pow(2.0, (bendSemitones + vibrato) / 12.0)
            tones.append(.init(frequencyHz: bentFrequency))

            let velocityLevel = Double(state.velocity) / 127.0
            let channelVolume = Double(volumes[key.channel] ?? 127) / 127.0
            let expression = Double(expressions[key.channel] ?? 127) / 127.0
            combinedLevel = max(combinedLevel, velocityLevel * channelVolume * expression)
        }

        guard !tones.isEmpty else { return }
        try? driver.play(.init(
            tones: tones,
            durationMS: 36,
            level: min(1, combinedLevel * levelScale)
        ))
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        lock.lock()
        let active = enabled
        lock.unlock()
        guard active else { return }

        var packet = eventList.pointee.packet
        for _ in 0..<Int(eventList.pointee.numPackets) {
            let wordCount = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { bytes in
                let words = bytes.bindMemory(to: UInt32.self)
                for index in 0..<min(wordCount, words.count) {
                    handleUMP(words[index])
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func handleUMP(_ word: UInt32) {
        let messageType = Int((word >> 28) & 0xF)
        guard messageType == 0x2 else { return }

        let statusByte = Int((word >> 16) & 0xFF)
        let command = statusByte & 0xF0
        let channel = statusByte & 0x0F
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)

        switch command {
        case 0x80:
            noteOff(channel: channel, note: data1, velocity: data2)
        case 0x90:
            if data2 == 0 {
                noteOff(channel: channel, note: data1, velocity: 0)
            } else {
                noteOn(channel: channel, note: data1, velocity: data2)
            }
        case 0xB0:
            controlChange(channel: channel, controller: data1, value: data2)
        case 0xD0:
            lock.lock()
            channelPressureByChannel[channel] = data1
            lock.unlock()
        case 0xE0:
            let bend = data1 | (data2 << 7)
            lock.lock()
            pitchBendByChannel[channel] = bend
            lock.unlock()
        default:
            break
        }
    }

    private func noteOn(channel: Int, note: Int, velocity: Int) {
        let key = NoteKey(channel: channel, note: note)
        lock.lock()
        if var state = activeNotes[key] {
            state.velocity = max(state.velocity, velocity)
            state.keyDownCount += 1
            state.releasedWhileSustained = false
            activeNotes[key] = state
        } else {
            activeNotes[key] = ActiveNote(
                velocity: velocity,
                keyDownCount: 1,
                releasedWhileSustained: false
            )
        }
        lock.unlock()
        callback?(.init(channel: channel, note: note, velocity: velocity, isNoteOn: true))
    }

    private func noteOff(channel: Int, note: Int, velocity: Int) {
        let key = NoteKey(channel: channel, note: note)
        lock.lock()
        if var state = activeNotes[key] {
            state.keyDownCount = max(0, state.keyDownCount - 1)
            if state.keyDownCount > 0 {
                activeNotes[key] = state
            } else if sustainByChannel[channel] == true {
                state.releasedWhileSustained = true
                activeNotes[key] = state
            } else {
                activeNotes.removeValue(forKey: key)
            }
        }
        lock.unlock()
        callback?(.init(channel: channel, note: note, velocity: velocity, isNoteOn: false))
    }

    private func controlChange(channel: Int, controller: Int, value: Int) {
        let safeValue = max(0, min(127, value))

        lock.lock()
        switch controller {
        case 1:
            // Modulation wheel. Use it as vibrato depth, matching the musical role
            // players expect from the wheel beside pitch bend.
            modulationByChannel[channel] = safeValue

        case 7:
            volumeByChannel[channel] = safeValue

        case 11:
            expressionByChannel[channel] = safeValue

        case 64:
            let sustainOn = safeValue >= 64
            sustainByChannel[channel] = sustainOn
            if !sustainOn {
                activeNotes = activeNotes.filter { key, state in
                    key.channel != channel || state.keyDownCount > 0
                }
            }

        case 100:
            rpnLSBByChannel[channel] = safeValue

        case 101:
            rpnMSBByChannel[channel] = safeValue

        case 6:
            // RPN 0,0 = Pitch Bend Sensitivity, MSB = semitones.
            if rpnMSBByChannel[channel] == 0, rpnLSBByChannel[channel] == 0 {
                bendRangeSemitonesByChannel[channel] = safeValue
                let cents = bendRangeCentsByChannel[channel] ?? 0
                pitchBendRangeByChannel[channel] = Double(safeValue) + Double(cents) / 100.0
            }

        case 38:
            // RPN 0,0 Data Entry LSB = cents.
            if rpnMSBByChannel[channel] == 0, rpnLSBByChannel[channel] == 0 {
                bendRangeCentsByChannel[channel] = min(99, safeValue)
                let semitones = bendRangeSemitonesByChannel[channel] ?? 2
                pitchBendRangeByChannel[channel] = Double(semitones) + Double(min(99, safeValue)) / 100.0
            }

        case 120, 123:
            // All Sound Off / All Notes Off.
            activeNotes = activeNotes.filter { key, _ in key.channel != channel }

        case 121:
            // Reset All Controllers.
            sustainByChannel[channel] = false
            pitchBendByChannel[channel] = 8192
            pitchBendRangeByChannel[channel] = 2.0
            modulationByChannel[channel] = 0
            volumeByChannel[channel] = 127
            expressionByChannel[channel] = 127
            channelPressureByChannel[channel] = 0
            activeNotes = activeNotes.filter { key, state in
                key.channel != channel || state.keyDownCount > 0
            }

        default:
            break
        }
        lock.unlock()
    }

    private func sendPitchBendRange(semitones: Int, channel: Int) {
        let value = max(0, min(24, semitones))
        sendMIDI1(status: 0xB0 | channel, data1: 101, data2: 0)
        sendMIDI1(status: 0xB0 | channel, data1: 100, data2: 0)
        sendMIDI1(status: 0xB0 | channel, data1: 6, data2: value)
        sendMIDI1(status: 0xB0 | channel, data1: 38, data2: 0)
        sendMIDI1(status: 0xB0 | channel, data1: 101, data2: 127)
        sendMIDI1(status: 0xB0 | channel, data1: 100, data2: 127)
    }

    private func sendPitchBend(_ value: Int, channel: Int) {
        let safe = max(0, min(16383, value))
        let lsb = safe & 0x7F
        let msb = (safe >> 7) & 0x7F
        sendMIDI1(status: 0xE0 | channel, data1: lsb, data2: msb)
    }

    private func sendMIDI1(status: Int, data1: Int, data2: Int) {
        guard virtualSource != 0 else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        let bytes = [UInt8(status & 0xFF), UInt8(data1 & 0x7F), UInt8(data2 & 0x7F)]
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = MIDIPacketListAdd(
                &packetList,
                MemoryLayout<MIDIPacketList>.size,
                packet,
                0,
                bytes.count,
                base
            )
        }
        MIDIReceived(virtualSource, &packetList)
    }
}
#endif
