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

public enum TouchMIDIMode: String, CaseIterable, Identifiable, Sendable, Codable {
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
    case outgoingRecoveryRequired

    public var errorDescription: String? {
        switch self {
        case .client(let status):
            if status == -2 || status == -304 {
                return "CoreMIDI client creation failed (OSStatus \(status)). The MIDI session was not started. If the error persists, quit and relaunch the app; check Audio MIDI Setup. No automatic reconnect is attempted."
            }
            return "CoreMIDI client creation failed (OSStatus \(status))."
        case .destination(let status): return "CoreMIDI virtual input creation failed (OSStatus \(status))."
        case .source(let status): return "CoreMIDI virtual output creation failed (OSStatus \(status))."
        case .inputPort(let status): return "CoreMIDI input port creation failed (OSStatus \(status))."
        case .outgoingRecoveryRequired: return "MIDI cleanup is unconfirmed. Retry Stop. For an unknown controller failure, reset the DAW and quit/relaunch this app."
        }
    }
}

/// CoreMIDI's on-demand MIDIServer may tear down its IPC channel when the
/// process disposes its last MIDI client. After that, subsequent creation can
/// return OSStatus -2 until process restart. Keep exactly one client alive for
/// the lifetime of the app, including across MIDI mode switches and reconnects.
final class MIDIProcessClient: @unchecked Sendable {
    static let shared = MIDIProcessClient()
    private let lock = NSLock()
    private var retainedClient = MIDIClientRef()
    private var isolatedSources: Set<MIDIEndpointRef> = []

    func registerIsolatedSource(_ source: MIDIEndpointRef) {
        lock.lock(); defer { lock.unlock() }
        isolatedSources.insert(source)
    }

    func unregisterIsolatedSource(_ source: MIDIEndpointRef) {
        lock.lock(); defer { lock.unlock() }
        isolatedSources.remove(source)
    }

    func isIsolatedSource(_ source: MIDIEndpointRef) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isolatedSources.contains(source)
    }

    func acquire() throws -> MIDIClientRef {
        lock.lock()
        defer { lock.unlock() }
        if retainedClient != 0 { return retainedClient }
        var newClient = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(
            "Tihulu Trackpad & M. Mouse Instrument" as CFString, &newClient
        ) { @Sendable _ in }
        guard status == noErr,newClient != 0 else {
            // A successful status with a null handle is not an admitted
            // client. Do not cache it or attempt to use it.
            throw MIDIHapticError.client(status == noErr ? -1 : status)
        }
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

    private struct TouchKey: Hashable, Comparable {
        let surface: TouchSurfaceKind
        let id: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.surface == rhs.surface ? lhs.id < rhs.id : lhs.surface.rawValue < rhs.surface.rawValue
        }
    }

    private struct OutgoingTouch {
        var note: Int
        var channel: Int
        var fretless: Bool
        var mpe: Bool
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
    private var receiveEpoch = LegacyReceiveEpoch()
    private var callback: (@Sendable (LiveMIDIMessage) -> Void)?

    private var incomingNotes = LegacyIncomingNotes()
    private var incomingHapticAttacks = HapticAttackBuffer<SensorCommand>()
    private var pitchBendByChannel: [Int: Int] = [:]
    private var incomingBendRanges: [Int:LegacyBendRangeState] = [:]
    private var modulationByChannel: [Int: Int] = [:]
    private var volumeByChannel: [Int: Int] = [:]
    private var expressionByChannel: [Int: Int] = [:]
    private var channelPressureByChannel: [Int: Int] = [:]
    private var renderTimer: DispatchSourceTimer?
    private let renderFence = HapticSourceFence()
    private var inputHapticsEnabled = true

    private enum OutgoingNoteOwner: Hashable {
        case touch(TouchKey), physicalChord(TouchKey, SensorDestination), legacyTouch, performance(NoteKey)
    }
    private var noteOwners = LegacyNoteOwners<OutgoingNoteOwner>()
    private var outgoingTouches: [TouchKey: OutgoingTouch] = [:]
    private var physicalChordGates = PhysicalChordGates<TouchKey>()
    private var touchOutputNote: Int?
    private var touchOutputChannel = 0
    private var touchOutputFretless = false

    // Main-actor callers serialize outgoing control changes; the service
    // lock protects state shared with the incoming MIDI render path.
    private var sustainOwners = LegacySustainOwners()
    private var mpeChannels = LegacyMPEChannelPool()
    private var continuousOwners = LegacyContinuousOwners()
    private var outgoingPressure = LegacyChannelPressure()
    // Outgoing state is serialized by the existing Studio caller.
    private var gateDebt = LegacyGateReleaseDebt()
    public private(set) var keyboardOutputAudit:KeyboardOutputAudit?
    public func beginKeyboardOutputAudit() { keyboardOutputAudit = .init() }
    public func endKeyboardOutputAudit() -> KeyboardOutputAudit? {
        let result = keyboardOutputAudit; keyboardOutputAudit = nil; return result
    }
    private var controllerDebt = LegacyControllerReleaseDebt()
    private var outgoingFault: OSStatus?
    private var controllerRecoveryRequired = false
    private var cleaningOutgoing = false
    private var outgoingFailureHandler: (@Sendable (OSStatus) -> Void)?

    public var hasUnconfirmedOutgoingCleanup: Bool {
        !LegacyRecoveryPolicy.permitsReplacement(gatesPending:!gateDebt.isEmpty,
            controllersPending:!controllerDebt.isEmpty,unknownFailure:controllerRecoveryRequired)
    }
    public var requiresManualDAWReset: Bool { controllerRecoveryRequired }

    private var permitsOutgoingSend: Bool {
        lock.lock()
        let running = enabled
        lock.unlock()
        return LegacyRecoveryPolicy.permitsSend(enabled:running,faulted:outgoingFault != nil,cleaning:cleaningOutgoing)
    }
    public var outgoingFailureStatus: OSStatus? { outgoingFault }

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    deinit {
        stop()
        disposeEndpoints()
    }

    public func start(masterLevel: Double, onFailure: (@Sendable (OSStatus) -> Void)? = nil, onMessage: (@Sendable (LiveMIDIMessage) -> Void)? = nil) throws {
        lock.lock()
        let alreadyActive = enabled && destination != 0 && virtualSource != 0 && inputPort != 0
        self.masterLevel = masterLevel
        if alreadyActive {
            // Retain the current session and its input-haptics policy.
            self.callback = onMessage
            lock.unlock()
            return
        }
        lock.unlock()

        // Soft-stop note/controller state without closing the virtual MIDI
        // endpoints. Logic retains the same endpoints across mode switches.
        stop()
        guard !hasUnconfirmedOutgoingCleanup else { throw MIDIHapticError.outgoingRecoveryRequired }
        outgoingFault = nil
        outgoingFailureHandler = onFailure
        if client == 0 { client = try MIDIProcessClient.shared.acquire() }
        if destination == 0 || virtualSource == 0 || inputPort == 0 {
            // Clean up any partial endpoints left by a previous failed start,
            // while keeping the process-wide CoreMIDI client alive.
            disposeEndpoints()
            try createEndpoints()
        }

        lock.lock()
        self.callback = onMessage
        self.inputHapticsEnabled = true
        receiveEpoch.begin()
        enabled = true
        incomingNotes = LegacyIncomingNotes()
        incomingHapticAttacks.removeAll()
        pitchBendByChannel.removeAll()
        incomingBendRanges.removeAll()
        modulationByChannel.removeAll()
        volumeByChannel.removeAll()
        expressionByChannel.removeAll()
        channelPressureByChannel.removeAll()
        outgoingTouches.removeAll()
        physicalChordGates = PhysicalChordGates<TouchKey>()
        sustainOwners = LegacySustainOwners()
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
            if source != 0, source != virtualSource, !MIDIProcessClient.shared.isIsolatedSource(source) {
                MIDIPortConnectSource(inputPort, source, nil)
            }
        }

    }

    public func stop() {
        // Close input first; outgoing note/pedal release still needs enabled.
        lock.lock()
        receiveEpoch.end()
        callback = nil
        lock.unlock()
        renderFence.revoke()
        cleaningOutgoing = true
        // Full shutdown: every logical owner is leaving. Never emit a
        // fallback value from a departing owner or a neutral for an onset
        // suppressed after a fault. The actual-attempt ledgers are sufficient.
        noteOwners = LegacyNoteOwners<OutgoingNoteOwner>()
        continuousOwners = LegacyContinuousOwners()
        outgoingPressure = LegacyChannelPressure()
        mpeChannels = LegacyMPEChannelPool()
        touchOutputNote = nil
        touchOutputFretless = false
        // Retry only the outstanding attempted note/pedal destinations.
        // Sustain-off precedes note-off; continuous cleanup follows the gates.
        for message in gateDebt.pending { sendMIDI1(status:message.status,data1:message.data1,data2:message.data2) }
        for channel in controllerDebt.pendingRanges {
            let msb = sendMIDI1(status:0xb0|channel,data1:101,data2:127,rangePart:true)
            let lsb = sendMIDI1(status:0xb0|channel,data1:100,data2:127,rangePart:true)
            if msb && lsb { controllerDebt.completeRange(channel:channel) }
        }
        for message in controllerDebt.pending {
            let neutral = (message.status & 0xf0) == 0xb0 ? message.data2 : LegacyControllerReleaseDebt.neutral(for:message)
            sendMIDI1(status:message.status,data1:message.data1,data2:message.data2,neutral:neutral)
        }
        cleaningOutgoing = false
        outgoingFailureHandler = nil

        lock.lock()
        enabled = false
        incomingNotes = LegacyIncomingNotes()
        incomingHapticAttacks.removeAll()
        pitchBendByChannel.removeAll()
        incomingBendRanges.removeAll()
        modulationByChannel.removeAll()
        volumeByChannel.removeAll()
        expressionByChannel.removeAll()
        channelPressureByChannel.removeAll()
        outgoingTouches.removeAll()
        physicalChordGates = PhysicalChordGates<TouchKey>()
        sustainOwners = LegacySustainOwners()
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
        if !enabled { incomingHapticAttacks.removeAll() }
        lock.unlock()
        if !enabled { renderFence.drain() }
    }

    // Called from the existing serialized outgoing MIDI path. Incoming
    // CoreMIDI notes have a separate ledger and never enter these owners.
    private func sendOwnedNotes(_ commands: [SensorCommand]) {
        for c in commands {
            sendMIDI1(status:(c.value == 0 ? 0x80 : 0x90) | c.destination.channel,
                      data1:c.destination.number,data2:c.value)
        }
    }

    public func sendTouchStates(
        _ states: [TouchPerformanceState],
        configuration: TouchInstrumentConfiguration,
        midiMode: TouchMIDIMode,
        baseChannel: Int = 0,
        multiTouchEnabled: Bool = true,
        separateChannels: DAWSurfaceChannels? = nil,
        sustainNewVoices: Bool = false,
        admitOnset: () -> Bool = { true }
    ) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }
        guard configuration.hasValidSampleDomain else {
            releaseTouchSustain()
            endAllTouchOutput()
            return
        }

        // GM percussion is always MIDI Channel 10 (zero-based 9). Pitched notes
        // stay on the requested channel, except channel 10 is reserved whenever
        // a drum surface is configured at the same time.
        let anyDrums = configuration.selectedSurfaces.contains {
            configuration.instrument(for: $0) == .drums &&
            configuration.output(for: $0).sendsMIDI
        }
        let safeMelodicChannel = SurfaceMIDIChannel.melodic(base: baseChannel, hasMIDIDrums: anyDrums)
        if separateChannels != nil && (midiMode != .standard || !configuration.permitsSeparateDAWSurfaceChannels) {
            releaseTouchSustain()
            endAllTouchOutput()
            return
        }
        func melodicChannel(_ surface: TouchSurfaceKind) -> Int {
            guard let split = separateChannels else { return safeMelodicChannel }
            return surface == .trackpad ? split.trackpad : split.magicMouse
        }

        let stringRouteAllowed = configuration.permitsStringMIDI(isMPE:midiMode == .mpe)
        let melodicRouteAllowed = configuration.permitsMelodicMIDI(isMPE:midiMode == .mpe)
        var desired = states.filter {
            $0.isDown && $0.isTouching && $0.continuousMIDI.isFinite && $0.vibrato.isFinite &&
            HelperPerformancePolicy.validContact(x:$0.x,y:$0.y,size:$0.pressure) &&
            configuration.surfaceSelection.accepts($0.surface) && configuration.output(for: $0.surface).sendsMIDI &&
            (!configuration.instrument(for:$0.surface).isStringSurface || stringRouteAllowed) &&
            (configuration.instrument(for:$0.surface) != .melodic || melodicRouteAllowed) &&
            (configuration.instrument(for:$0.surface) != .fretlessStrings || configuration.strings(for:$0.surface).continuousCell(x:$0.x,y:$0.y) != nil)
        }
        func key(for state:TouchPerformanceState) -> TouchKey {
            TouchKey(surface:state.surface,id:state.contactID)
        }
        let heldKeys = Set(outgoingTouches.keys).union(physicalChordGates.contacts)
        if !multiTouchEnabled {
            if let index = LegacyTouchAdmission.preferredIndex(keys:desired.map { key(for:$0) },held:heldKeys) {
                desired = [desired[index]]
            }
        }
        if configuration.fretless, midiMode == .standard {
            // Keep nonmelodic routes independent. Do not move a channel-wide
            // bend to a different finger merely because native order changed.
            let melodic = desired.filter { configuration.instrument(for:$0.surface) == .melodic }
            let chosen = LegacyTouchAdmission.preferredIndex(keys:melodic.map { key(for:$0) },held:heldKeys)
                .map { key(for:melodic[$0]) }
            desired = desired.filter {
                configuration.instrument(for:$0.surface) != .melodic || key(for:$0) == chosen
            }
        }

        // Chords are standard MIDI, not disguised MPE notes. Invalid routes
        // release existing physical chord ownership without touching other sources.
        var chordTargets: [TouchKey:Set<SensorDestination>] = [:]
        var chordVelocities: [TouchKey:Int] = [:]
        if configuration.permitsPhysicalChordMIDI(isMPE:midiMode == .mpe),
           let bank = configuration.physicalChordBank {
            for state in desired where configuration.instrument(for:state.surface) == .chords {
                guard let slot = state.chordSlot, let pad = bank.pad(at:slot) else { continue }
                let key = TouchKey(surface:state.surface,id:state.contactID)
                chordTargets[key] = Set(pad.notes.map { .init(.note,channel:melodicChannel(state.surface),number:$0) })
                chordVelocities[key] = max(1,min(127,state.velocity))
            }
        }
        desired.removeAll { configuration.instrument(for:$0.surface) == .chords }
        guard physicalChordGates.reconcileAdmitted(chordTargets,velocity:chordVelocities,
            ledger:&noteOwners,owner:{ .physicalChord($0,$1) },permits:admitOnset,
            send:{ self.sendOwnedNotes([$0]) }) else { return }
        let desiredKeys = Set(desired.map { TouchKey(surface: $0.surface, id: $0.contactID) })
        let releasedKeys = outgoingTouches.keys.filter { !desiredKeys.contains($0) }
        for key in releasedKeys {
            guard let outgoing = outgoingTouches.removeValue(forKey: key) else { continue }
            releaseOutgoingTouch(key,outgoing:outgoing)
        }

        var frameControls: [SensorDestination:LegacyContinuousOwners.Value] = [:]
        var framePressure: [Int:Int] = [:]
        var processed: Set<TouchKey> = []
        for state in desired {
            guard admitOnset() else { return }
            let key = TouchKey(surface: state.surface, id: state.contactID)
            let drums = configuration.instrument(for: state.surface) == .drums
            guard processed.insert(key).inserted else { continue }
            let instrument = configuration.instrument(for:state.surface)
            let isGuitar = instrument.isStringSurface
            let layout = configuration.strings(for:state.surface)
            let stringCell = instrument == .fretlessStrings
                ? layout.continuousCell(x:state.x,y:state.y)
                : (instrument == .guitar ? layout.microtonalCell(x:state.x,y:state.y) : nil)
            if instrument == .guitar && layout.isMicrotonal && stringCell == nil {
                if let old = outgoingTouches.removeValue(forKey:key) { releaseOutgoingTouch(key,outgoing:old) }
                continue
            }
            let tunedMelody = instrument == .melodic ? configuration.melodicMPEPitch(midi:state.quantizedMIDI,isMPE:midiMode == .mpe) : nil
            if instrument == .melodic && !configuration.fretless && midiMode == .mpe && configuration.customScale?.isMicrotonal == true && tunedMelody == nil {
                if let old = outgoingTouches.removeValue(forKey:key) { releaseOutgoingTouch(key,outgoing:old) }
                continue
            }
            let isFretlessMelody = stringCell != nil || tunedMelody != nil || (instrument == .melodic && configuration.fretless)
            let isMPE = midiMode == .mpe && !drums
            let standardChannel = drums ? GMDrumPads.midiChannel : melodicChannel(state.surface)
            let anchor = stringCell?.anchor ?? tunedMelody?.anchor ?? max(0,min(127,configuration.baseMIDINote +
                Int((configuration.pitchSpanSemitones / 2.0).rounded())))
            let targetNote = isFretlessMelody ? anchor : max(0,min(127,state.quantizedMIDI))
            if let existing = outgoingTouches[key],
               (((stringCell != nil || tunedMelody != nil) && existing.note != anchor) || LegacyTouchTransition.requiresNewVoice(oldNote:existing.note,oldFretless:existing.fretless,
                   oldMPE:existing.mpe,oldChannel:existing.channel,newNote:targetNote,newFretless:isFretlessMelody,
                   newMPE:isMPE,standardChannel:standardChannel,
                   sustained:outgoingSustainChannels().contains(existing.channel))) {
                outgoingTouches.removeValue(forKey:key)
                releaseOutgoingTouch(key,outgoing:existing)
            }
            let channel: Int

            if let existing = outgoingTouches[key] {
                channel = existing.channel
            } else if drums {
                channel = GMDrumPads.midiChannel
            } else if midiMode == .mpe {
                // Lower-zone MPE member channels, skipping the GM percussion
                // channel even when drum and pitched surfaces run together.
                let used = Set(outgoingTouches.values.map(\.channel))
                    .union(noteOwners.active.map(\.channel))
                guard let free = mpeChannels.next(occupied:used,sustained:outgoingSustainChannels()) else { continue }
                channel = free
            } else {
                channel = standardChannel
            }

            // A newly allocated MPE member must receive this frame's
            // admitted pedal before expression and Note On, not afterwards.
            // Do not mark unused members sustained before allocation.
            if isMPE && sustainNewVoices && outgoingTouches[key] == nil {
                guard admitOnset() else { return }
                extendTouchSustain(to:channel)
            }

            // Onsets must not inherit a retired member's expression/pressure.
            // Ordinary shared channels still use the existing final-contact rule.
            if !drums {
                let vibrato = max(0,min(127,Int((min(1,max(0,state.vibrato))*127).rounded())))
                let modulation = SensorDestination(.controlChange,channel:channel,number:1)
                if !isGuitar { frameControls[modulation] = .init(vibrato,neutral:0) }
                if configuration.pressureToExpression {
                    let expression = SensorDestination(.controlChange,channel:channel,number:11)
                    frameControls[expression] = .init(max(0,min(127,state.expression)),neutral:127)
                    if isMPE { framePressure[channel] = max(0,min(127,state.expression)) }
                }
                if outgoingTouches[key] == nil {
                    // Preserve other active channels while initializing this one.
                    // A reused continuous-pitch channel is about to receive its
                    // new bend before note-on. Keep the old bend ownership until
                    // then, rather than send a gratuitous neutral and repeat RPN.
                    var staged = continuousOwners.values(for:.touch).filter {
                        $0.key.channel != channel || (isFretlessMelody && $0.key.kind == .pitchBend)
                    }
                    for (target,value) in frameControls where target.channel == channel { staged[target] = value }
                    sendContinuousUpdates(continuousOwners.replace(.touch,values:staged))
                    if isMPE {
                        var pressure = outgoingPressure.values
                        pressure[channel] = framePressure[channel]
                        sendPressureUpdates(outgoingPressure.replace(pressure))
                    }
                }
            }
            if isFretlessMelody {
                let bendRange = stringCell?.bendRange ?? tunedMelody?.bendRange ?? max(1, min(24, Int(ceil(configuration.pitchSpanSemitones / 2.0))))

                let delta = max(-Double(bendRange),
                    min(Double(bendRange), state.continuousMIDI - Double(anchor)))
                let bend = stringCell?.bend ?? tunedMelody?.bend ?? Int((8192.0 + (delta / Double(bendRange)) * 8191.0).rounded())
                let target = SensorDestination(.pitchBend,channel:channel)
                let value = LegacyContinuousOwners.Value(max(0,min(16383,bend)),neutral:8192,bendRange:bendRange)
                frameControls[target] = value
                // Held voices are reconciled once at frame end. Onsets and
                // rearticulations still establish pitch/range before the note.
                if let existing = outgoingTouches[key] {
                    if existing.note != anchor || !existing.fretless {
                        sendContinuousUpdates(continuousOwners.set(.touch,target:target,value:value))
                        sendOwnedNotes(noteOwners.release(.touch(key)))
                        guard noteOwners.pressAdmitted(.touch(key),channel:channel,note:anchor,velocity:max(1,min(127,state.velocity)),
                            permits:admitOnset,send:{ self.sendOwnedNotes([$0]) }) else { return }
                        outgoingTouches[key] = .init(note: anchor, channel: channel, fretless: true, mpe: midiMode == .mpe)
                    }
                } else {
                    sendContinuousUpdates(continuousOwners.set(.touch,target:target,value:value))
                    guard noteOwners.pressAdmitted(.touch(key),channel:channel,note:anchor,velocity:max(1,min(127,state.velocity)),
                            permits:admitOnset,send:{ self.sendOwnedNotes([$0]) }) else { return }
                    outgoingTouches[key] = .init(note: anchor, channel: channel, fretless: true, mpe: midiMode == .mpe)
                }

            } else {
                // Drums use actual GM note numbers (kick 36, snare 38, hats
                // 42/46 etc.). MIDI Channel 10 alone does not convert
                // pitched notes into drum pads.
                let note = max(0, min(127, state.quantizedMIDI))
                if let existing = outgoingTouches[key] {
                    if existing.note != note || existing.fretless {
                        sendOwnedNotes(noteOwners.release(.touch(key)))
                        guard noteOwners.pressAdmitted(.touch(key),channel:channel,note:note,velocity:max(1,min(127,state.velocity)),
                            permits:admitOnset,send:{ self.sendOwnedNotes([$0]) }) else { return }
                        outgoingTouches[key] = .init(note: note, channel: channel, fretless: false, mpe: midiMode == .mpe && !drums)
                    }
                } else {
                    guard noteOwners.pressAdmitted(.touch(key),channel:channel,note:note,velocity:max(1,min(127,state.velocity)),
                            permits:admitOnset,send:{ self.sendOwnedNotes([$0]) }) else { return }
                    outgoingTouches[key] = .init(note: note, channel: channel, fretless: false, mpe: midiMode == .mpe && !drums)
                }
            }

        }
        guard admitOnset() else { return }
        // Retired MPE channels keep their final controller values until pedal off.
        for (target,value) in continuousOwners.values(for:.touch) where mpeChannels.reserved.contains(target.channel) {
            frameControls[target] = frameControls[target] ?? value
        }
        sendContinuousUpdates(continuousOwners.replace(.touch,values:frameControls))
        for (channel,value) in outgoingPressure.values where mpeChannels.reserved.contains(channel) {
            framePressure[channel] = framePressure[channel] ?? value
        }
        sendPressureUpdates(outgoingPressure.replace(framePressure))
    }

    private func outgoingSustainChannels() -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return sustainOwners.active
    }

    private func releaseOutgoingTouch(_ key: TouchKey, outgoing: OutgoingTouch) {
        sendOwnedNotes(noteOwners.release(.touch(key)))
        if outgoing.mpe {
            _ = mpeChannels.retire(channel:outgoing.channel,
                                  sustained:outgoingSustainChannels().contains(outgoing.channel),
                                  fretless:outgoing.fretless)
        }
        // Frame replacement below releases only targets no longer owned.
    }

    public func endAllTouchOutput() {
        sendOwnedNotes(physicalChordGates.reconcile([:],velocity:[:],ledger:&noteOwners,owner:{ .physicalChord($0,$1) }))
        for (key, outgoing) in outgoingTouches {
            releaseOutgoingTouch(key,outgoing:outgoing)
        }
        outgoingTouches.removeAll()
        let retained = continuousOwners.values(for:.touch).filter { mpeChannels.reserved.contains($0.key.channel) }
        sendContinuousUpdates(continuousOwners.replace(.touch,values:retained))
        sendPressureUpdates(outgoingPressure.replace(outgoingPressure.values.filter { mpeChannels.reserved.contains($0.key) }))
        endTouchOutput()
    }

    private func sendSustainTransitions(_ commands: [SensorCommand]) {
        for command in commands {
            sendControlChange(controller:64,value:command.value,channel:command.destination.channel)
        }
        reconcileSustainReservations()
    }

    private func reconcileSustainReservations() {
        let before = mpeChannels.reserved
        _ = mpeChannels.pedalChanged(sustained:outgoingSustainChannels())
        let released = before.subtracting(mpeChannels.reserved)
        let held = Set(outgoingTouches.values.map(\.channel))
        for channel in released.subtracting(held).sorted() {
            sendContinuousUpdates(continuousOwners.release(.touch,channel:channel))
            sendPressureUpdates(outgoingPressure.release(channel))
        }
    }

    private func replaceSustain(_ owner: LegacySustainOwners.Owner, channels: Set<Int>) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        let commands = sustainOwners.replace(owner,channels:canSend ? channels : [])
        lock.unlock()
        if canSend { sendSustainTransitions(commands) }
    }

    /// One accepted physical frame may change both pedal owners. Emit
    /// only the final union transition, never an intermediate OFF/ON.
    public func setPhysicalSustainFrame(touch: MIDIHelperSustainSnapshot?,
                                        separateChannels: DAWSurfaceChannels?,
                                        independent:Bool,fixedTouchChannels:Set<Int>,
                                        helper:Bool?,helperChannel:Int,
                                        admitOnset:(()->Bool)? = nil) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        var updates: [LegacySustainOwners.Owner:Set<Int>] = [:]
        if let touch {
            if !canSend {
                updates[.touch] = []
            } else if let separateChannels {
                updates[.touch] = separateChannels.sustainTargets(touch,independent:independent)
            } else {
                let current = Set(outgoingTouches.values.map(\.channel)).union(physicalChordGates.channels)
                updates[.touch] = LegacyTouchSustainTargets.routed(active:touch.isActive,
                    previous:sustainOwners.channels(for:.touch),current:current,fixed:fixedTouchChannels)
            }
        }
        if let helper {
            updates[.helper] = helper && canSend ? [max(0,min(15,helperChannel))] : []
        }
        if canSend,let admitOnset {
            // Outgoing changes are serialized by Studio. Never hold the
            // service lock across synchronous CoreMIDI calls.
            var staged=sustainOwners
            lock.unlock()
            _=staged.replaceFrameAdmitted(updates,permits:{
                admitOnset() && self.permitsOutgoingSend
            },send:{ command in
                self.sendControlChange(controller:64,value:command.value,channel:command.destination.channel)
            })
            lock.lock()
            sustainOwners=staged
            lock.unlock()
            reconcileSustainReservations()
        } else {
            let commands = sustainOwners.replaceFrame(updates)
            lock.unlock()
            if canSend { sendSustainTransitions(commands) }
        }
    }

    private func extendTouchSustain(to channel:Int) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        let targets = sustainOwners.channels(for:.touch).union([channel])
        let commands = sustainOwners.replace(.touch,channels:canSend ? targets : [])
        lock.unlock()
        if canSend { sendSustainTransitions(commands) }
    }

    public func setHelperSustain(_ active: Bool, channel: Int) {
        replaceSustain(.helper,channels:active ? [max(0,min(15,channel))] : [])
    }
    public func releaseHelperSustain() { replaceSustain(.helper,channels:[]) }

    public func setTouchBarSustain(_ active: Bool, channel: Int) {
        replaceSustain(.touchBar,channels:active ? [max(0,min(15,channel))] : [])
    }
    public func releaseTouchBarSustain() { replaceSustain(.touchBar,channels:[]) }

    /// Retains previously held MPE channels until this owner releases.
    public func setTouchSustain(_ active: Bool, baseChannel: Int, separateChannels: DAWSurfaceChannels? = nil,
                                allowIdleFallback:Bool = true) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        let previous = sustainOwners.channels(for:.touch)
        let currentNoteChannels = Set(outgoingTouches.values.map(\.channel)).union(physicalChordGates.channels)
        let targets = LegacyTouchSustainTargets.resolve(active:active && canSend,
            previous:previous,current:separateChannels?.all ?? currentNoteChannels,
            baseChannel:baseChannel,allowIdleFallback:allowIdleFallback)
        let commands = sustainOwners.replace(.touch,channels:targets)
        lock.unlock()
        if canSend { sendSustainTransitions(commands) }
    }
    /// Standard split mode has fixed channels; replace, never accumulate
    /// previously held channels as the MPE sustain path must do.
    public func setTouchSustainChannels(_ channels: Set<Int>) {
        replaceSustain(.touch,channels:channels)
    }
    public func releaseTouchSustain() { replaceSustain(.touch,channels:[]) }

    private func releaseAllOutgoingSustain() {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        let commands = sustainOwners.releaseAll()
        lock.unlock()
        if canSend { sendSustainTransitions(commands) }
    }

    private func sendContinuousUpdates(_ updates: [LegacyContinuousOwners.Update]) {
        for update in updates {
            let target = update.target
            switch target.kind {
            case .pitchBend:
                if let range = update.bendRange { sendPitchBendRange(semitones:range,channel:target.channel) }
                sendPitchBend(update.value,channel:target.channel)
            case .controlChange:
                sendMIDI1(status:0xb0|target.channel,data1:target.number,data2:update.value,neutral:update.neutral,persistentGain:update.preserveOnRelease)
            default: break
            }
        }
    }

    public func sendHelperControls(
        x: Double, y: Double, contactSize: Double, assignments: MIDIHelperAssignments,
        channel: Int, pitchBendRange: Int, vibratoCC: Int, expressionCC: Int,
        configureReceiverBendRange:Bool = false
    ) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend,let values = HelperPerformancePolicy.controls(x:x,y:y,size:contactSize,
            assignments:assignments,channel:channel,bendRange:pitchBendRange,
            vibratoCC:vibratoCC,expressionCC:expressionCC,
            configureReceiverBendRange:configureReceiverBendRange) else { return }
        sendContinuousUpdates(continuousOwners.replace(.helper,values:values))
    }

    /// Ordinary lift retires the helper owner. Persistent gain stays at its
    /// last intentional value unless another active internal owner takes over.
    public func idleHelperControls() {
        sendContinuousUpdates(continuousOwners.release(.helper))
    }

    public func resetHelperControls(
        assignments: MIDIHelperAssignments, channel: Int, vibratoCC: Int, expressionCC: Int
    ) {
        sendContinuousUpdates(continuousOwners.release(.helper))
    }

    public func sendHelperGesture(
        x: Double, y: Double, pressure: Double, mode: MIDIHelperMode, channel: Int,
        pitchBendRange: Int, vibratoCC: Int = 1, expressionCC: Int = 11
    ) {
        sendHelperControls(x:x,y:y,contactSize:pressure,
            assignments:.init(vibrato:mode == .vibrato || mode == .hybrid,
                              pitchBend:mode == .pitchBend || mode == .hybrid,
                              expression:mode == .expression || mode == .hybrid),
            channel:channel,pitchBendRange:pitchBendRange,vibratoCC:vibratoCC,expressionCC:expressionCC)
    }

    public func resetHelperGesture(
        mode: MIDIHelperMode, channel: Int, vibratoCC: Int = 1, expressionCC: Int = 11
    ) {
        sendContinuousUpdates(continuousOwners.release(.helper))
    }

    public func sendTouchBarControl(_ target: SensorDestination, value: Int, bendRange: Int? = nil) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }
        let neutral = target.kind == .pitchBend ? 8192 : ([7,11].contains(target.number) ? 127 : 0)
        sendContinuousUpdates(continuousOwners.set(.touchBar,target:target,
            value:.init(value,neutral:neutral,bendRange:bendRange)))
    }

    public func releaseTouchBarControls() {
        sendContinuousUpdates(continuousOwners.release(.touchBar))
    }

    public func sendControlChange(controller: Int, value: Int, channel: Int) {
        let cc = max(0, min(127, controller))
        let safeValue = max(0, min(127, value))
        let safeChannel = max(0, min(15, channel))
        sendMIDI1(status: 0xB0 | safeChannel, data1: cc, data2: safeValue)
    }

    /// Sends an explicit note from the Touch Bar or on-screen performance strip.
    /// A direct note-off is sent when the last owner of the note releases.
    public func sendPerformanceNote(note: Int, velocity: Int, isOn: Bool, channel: Int) {
        lock.lock()
        let canSend = enabled && virtualSource != 0
        lock.unlock()
        guard canSend else { return }
        let safeNote = max(0, min(127, note))
        let safeVelocity = max(0, min(127, velocity))
        let safeChannel = max(0, min(15, channel))
        let owner = OutgoingNoteOwner.performance(.init(channel:safeChannel,note:safeNote))
        if isOn && safeVelocity > 0 {
            sendOwnedNotes(noteOwners.press(owner,channel:safeChannel,note:safeNote,velocity:safeVelocity))
        } else {
            sendOwnedNotes(noteOwners.release(owner))
        }
    }

    private func sendPressureUpdates(_ updates: [LegacyChannelPressure.Update]) {
        for update in updates { sendChannelPressure(update.value,channel:update.channel) }
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

        if !isDown || !continuousMIDI.isFinite || !(0...127).contains(rootMIDI) {
            endTouchOutput()
            return
        }

        if fretless {
            let centerNote = max(0, min(127, rootMIDI + 12))
            let deltaSemitones = max(-12.0, min(12.0, continuousMIDI - Double(centerNote)))
            let bend = Int((8192.0 + (deltaSemitones / 12.0) * 8191.0).rounded())
            let target = SensorDestination(.pitchBend,channel:safeChannel)
            let value = LegacyContinuousOwners.Value(max(0,min(16383,bend)),neutral:8192,bendRange:12)
            if touchOutputNote != centerNote || !touchOutputFretless || touchOutputChannel != safeChannel {
                endTouchOutput()
                touchOutputChannel = safeChannel
                touchOutputFretless = true
                sendContinuousUpdates(continuousOwners.set(.legacyTouch,target:target,value:value))
                sendOwnedNotes(noteOwners.press(.legacyTouch,channel:safeChannel,note:centerNote,velocity:safeVelocity))
                touchOutputNote = centerNote
            }

            sendContinuousUpdates(continuousOwners.set(.legacyTouch,target:target,value:value))
        } else {
            let note = max(0, min(127, quantizedMIDI))
            if touchOutputNote != note || touchOutputFretless || touchOutputChannel != safeChannel {
                endTouchOutput()
                touchOutputChannel = safeChannel
                touchOutputFretless = false
                sendOwnedNotes(noteOwners.press(.legacyTouch,channel:safeChannel,note:note,velocity:safeVelocity))
                touchOutputNote = note
            }
        }
    }

    public func endTouchOutput() {
        guard touchOutputNote != nil else { return }
        sendOwnedNotes(noteOwners.release(.legacyTouch))
        sendContinuousUpdates(continuousOwners.release(.legacyTouch))
        touchOutputNote = nil
        touchOutputFretless = false
    }

    private func startRenderTimer() {
        let token = renderFence.begin()
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        // Match Touch Instrument's continuously refreshed feel instead of behaving like
        // isolated haptic taps. A short overlapping frame prevents audible gaps while a
        // MIDI key (or sustain pedal) remains logically active.
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.renderActiveNotes(token: token) }
        renderTimer = timer
        timer.resume()
    }

    private func renderActiveNotes(token: UUID) {
        lock.lock()
        let active = enabled
        let hapticsEnabled = inputHapticsEnabled
        var notes = incomingNotes.notes.prefix(6).map { (key:$0.key,velocity:$0.value.velocity) }
        let now = ProcessInfo.processInfo.systemUptime
        let attacks = incomingHapticAttacks.drain(now:now)
        var keys = Set(notes.map(\.key))
        for attack in attacks where notes.count < 6 {
            let key = LegacyIncomingNotes.Key(channel:attack.destination.channel,note:attack.destination.number)
            if keys.insert(key).inserted { notes.append((key:key,velocity:attack.value)) }
        }
        let bends = pitchBendByChannel
        let bendRanges = incomingBendRanges
        let modulation = modulationByChannel
        let volumes = volumeByChannel
        let expressions = expressionByChannel
        let pressures = channelPressureByChannel
        let levelScale = masterLevel
        lock.unlock()
        guard active, hapticsEnabled, !notes.isEmpty else { return }

        var tones: [HapticTone] = []
        var combinedLevel = 0.0

        for (key, velocity) in notes {
            guard let frequency = try? MusicTheory.frequency(midi: key.note) else { continue }

            let bend14 = bends[key.channel] ?? 8192
            let bendRange = bendRanges[key.channel]?.range ?? 2.0
            let bendNormalized = (Double(bend14) - 8192.0) / 8192.0
            let bendSemitones = bendNormalized * bendRange

            let modValue = Double(modulation[key.channel] ?? 0) / 127.0
            let pressureValue = Double(pressures[key.channel] ?? 0) / 127.0
            let vibratoDepthSemitones = 0.75 * max(modValue, pressureValue * 0.6)
            let vibrato = vibratoDepthSemitones * sin(now * 5.5 * 2.0 * Double.pi)

            let bentFrequency = frequency * pow(2.0, (bendSemitones + vibrato) / 12.0)
            tones.append(.init(frequencyHz: bentFrequency))

            let velocityLevel = Double(velocity) / 127.0
            let channelVolume = Double(volumes[key.channel] ?? 127) / 127.0
            let expression = Double(expressions[key.channel] ?? 127) / 127.0
            combinedLevel = max(combinedLevel, velocityLevel * channelVolume * expression)
        }

        guard !tones.isEmpty else { return }
        renderFence.submit(token) {
            lock.lock()
            let allowed = enabled && inputHapticsEnabled
            lock.unlock()
            guard allowed else { return }
            try? driver.play(.init(
                tones: tones,
                durationMS: 36,
                level: min(1, combinedLevel * levelScale)
            ))
        }
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        lock.lock()
        let token = receiveEpoch.token
        lock.unlock()
        guard let token else { return }

        LegacyMIDIEventReader.forEachMIDI1(in:eventList) { handleUMP($0,token:token) }
    }

    private func handleUMP(_ word: UInt32, token: UInt64) {
        let messageType = Int((word >> 28) & 0xF)
        guard messageType == 0x2 else { return }

        let statusByte = Int((word >> 16) & 0xFF)
        let command = statusByte & 0xF0
        let channel = statusByte & 0x0F
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)

        switch command {
        case 0x80:
            noteOff(channel: channel, note: data1, velocity: data2, token:token)
        case 0x90:
            if data2 == 0 {
                noteOff(channel: channel, note: data1, velocity: 0, token:token)
            } else {
                noteOn(channel: channel, note: data1, velocity: data2, token:token)
            }
        case 0xB0:
            controlChange(channel: channel, controller: data1, value: data2, token:token)
        case 0xD0:
            lock.lock()
            guard receiveEpoch.accepts(token) else { lock.unlock(); return }
            channelPressureByChannel[channel] = data1
            lock.unlock()
        case 0xE0:
            let bend = data1 | (data2 << 7)
            lock.lock()
            guard receiveEpoch.accepts(token) else { lock.unlock(); return }
            pitchBendByChannel[channel] = bend
            lock.unlock()
        default:
            break
        }
    }

    private func notifyIncoming(_ commands: [SensorCommand], using notify: (@Sendable (LiveMIDIMessage) -> Void)?) {
        for c in commands {
            notify?(.init(channel:c.destination.channel,note:c.destination.number,velocity:c.value,isNoteOn:c.value>0))
        }
    }

    private func noteOn(channel: Int, note: Int, velocity: Int, token: UInt64) {
        lock.lock()
        guard receiveEpoch.accepts(token) else { lock.unlock(); return }
        let commands = incomingNotes.noteOn(channel:channel,note:note,velocity:velocity)
        if inputHapticsEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            for command in commands where command.destination.kind == .note && command.value > 0 {
                incomingHapticAttacks.offer(command,now:now)
            }
        }
        let notify = callback
        lock.unlock()
        notifyIncoming(commands,using:notify)
    }

    private func noteOff(channel: Int, note: Int, velocity: Int, token: UInt64) {
        lock.lock()
        guard receiveEpoch.accepts(token) else { lock.unlock(); return }
        let commands = incomingNotes.noteOff(channel:channel,note:note)
        let notify = callback
        lock.unlock()
        notifyIncoming(commands,using:notify)
    }

    private func controlChange(channel: Int, controller: Int, value: Int, token: UInt64) {
        let safeValue = max(0,min(127,value))
        lock.lock()
        guard receiveEpoch.accepts(token) else { lock.unlock(); return }
        let commands = incomingNotes.control(channel:channel,controller:controller,value:safeValue)
        // Explicit channel reset must not replay queued attacks.
        if [120,121,123].contains(controller) { incomingHapticAttacks.removeAll() }
        switch controller {
        case 1: modulationByChannel[channel] = safeValue
        case 7: volumeByChannel[channel] = safeValue
        case 11: expressionByChannel[channel] = safeValue
        case 6,38,98,99,100,101:
            incomingBendRanges[channel,default:.init()].control(controller,value:safeValue)
        case 121:
            incomingBendRanges.removeValue(forKey:channel)
            pitchBendByChannel[channel] = 8192
            modulationByChannel[channel] = 0
            volumeByChannel[channel] = 127
            expressionByChannel[channel] = 127
            channelPressureByChannel[channel] = 0
        default: break
        }
        let notify = callback
        lock.unlock()
        notifyIncoming(commands,using:notify)
    }

    private func sendPitchBendRange(semitones: Int, channel: Int) {
        guard permitsOutgoingSend else { return }
        controllerDebt.beginRange(channel:channel)
        let value = max(0,min(24,semitones))
        let parts = [(101,0),(100,0),(6,value),(38,0),(101,127),(100,127)]
        for (cc,v) in parts {
            guard sendMIDI1(status:0xb0|channel,data1:cc,data2:v,rangePart:true) else { return }
        }
        controllerDebt.completeRange(channel:channel)
    }

    private func sendPitchBend(_ value: Int, channel: Int) {
        let safe = max(0, min(16383, value))
        let lsb = safe & 0x7F
        let msb = (safe >> 7) & 0x7F
        sendMIDI1(status: 0xE0 | channel, data1: lsb, data2: msb)
    }

    @discardableResult
    private func sendMIDI1(status: Int, data1: Int, data2: Int, neutral: Int? = nil, rangePart: Bool = false,persistentGain:Bool = false) -> Bool {
        guard permitsOutgoingSend else { return false }
        let message = LegacyGateReleaseDebt.Message(status,data1,data2)
        var result: OSStatus = -1
        if virtualSource != 0 {
            var packetList = MIDIPacketList()
            let packet = MIDIPacketListInit(&packetList)
            let bytes = LegacyMIDI1Bytes.channelMessage(status:status,data1:data1,data2:data2)
            let added = bytes.withUnsafeBufferPointer { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                return MIDIPacketListAdd(&packetList,MemoryLayout<MIDIPacketList>.size,
                                         packet,0,bytes.count,base) != nil
            }
            if added { result = MIDIReceived(virtualSource,&packetList) }
        }
        keyboardOutputAudit?.record(message,succeeded:result == noErr)
        gateDebt.record(message,succeeded:result == noErr)
        let isPersistentGain = persistentGain && status & 0xf0 == 0xb0 && [7,11].contains(data1)
        let cleanupValue = isPersistentGain ? nil : (neutral ?? LegacyControllerReleaseDebt.neutral(for:message))
        if isPersistentGain { controllerDebt.forgetPersistentGain(message) }
        if let cleanupValue {
            controllerDebt.record(message,neutral:cleanupValue,succeeded:result == noErr)
        }
        guard result != noErr else { return true }
        if !LegacyGateReleaseDebt.isGate(message) && cleanupValue == nil && !rangePart { controllerRecoveryRequired = true }
        if outgoingFault == nil {
            outgoingFault = result
            // The handler schedules scoped stop on MainActor, never reenters
            // the intended-owner state machines from inside this send.
            outgoingFailureHandler?(result)
        }
        return false
    }
}

/// Dedicated virtual source, using the existing process-wide CoreMIDI client.
/// No input port, haptic driver or legacy note/controller state is modified.
/// Owned and called only on the main actor.
@MainActor
public final class ChordMIDIOutput {
    private var endpoint = MIDIEndpointRef()
    private let name: String
    public init(name: String = "TIHULU Chord Pads") { self.name = name }

    public func open() throws {
        if endpoint != 0 { return }
        let client = try MIDIProcessClient.shared.acquire()
        var source = MIDIEndpointRef()
        let status = MIDISourceCreate(client, name as CFString, &source)
        guard status == noErr else { throw MIDIHapticError.source(status) }
        endpoint = source
        MIDIProcessClient.shared.registerIsolatedSource(source)
    }

    /// Return CoreMIDI's delivery status; never report success on a failed send.
    public func send(_ command: SensorCommand) -> Bool {
        Self.send(command,endpoint:endpoint)
    }

    fileprivate static func send(_ command: SensorCommand, endpoint: MIDIEndpointRef) -> Bool {
        guard endpoint != 0, command.destination.isValid else { return false }
        let channel = command.destination.channel
        let value = command.value
        let bytes: [UInt8]
        switch command.destination.kind {
        case .note:
            guard (0...127).contains(value) else { return false }
            bytes = [UInt8((value > 0 ? 0x90 : 0x80) | channel), UInt8(command.destination.number), UInt8(value)]
        case .controlChange, .sustain:
            guard (0...127).contains(value) else { return false }
            let cc = command.destination.kind == .sustain ? 64 : command.destination.number
            bytes = [UInt8(0xB0 | channel), UInt8(cc), UInt8(value)]
        case .pitchBend:
            guard (0...16383).contains(value) else { return false }
            bytes = [UInt8(0xE0 | channel), UInt8(value & 127), UInt8(value >> 7)]
        }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        let added = bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard let first = buffer.baseAddress else { return false }
            return MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet,
                                     0, buffer.count, first) != nil
        }
        return added && MIDIReceived(endpoint, &list) == noErr
    }
    /// Only the three typed realtime transport messages are permitted.
    public func sendRealtime(_ message:EnsembleClock.Message) -> Bool {
        guard endpoint != 0 else { return false }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        var byte = message.rawValue
        let added = MIDIPacketListAdd(&list,MemoryLayout<MIDIPacketList>.size,packet,0,1,&byte) != nil
        return added && MIDIReceived(endpoint,&list) == noErr
    }
    // Keep the endpoint stable until process exit, as with the retained client.
}
/// Explicit experimental host. No UI or adapter calls start in this slice.
/// Retains one process-wide owner so failed note-off or disposal debt cannot
/// be lost by dropping a temporary view or recreating a controller.
@MainActor
public final class PerformanceGroupMIDIHost {
    public static let shared = PerformanceGroupMIDIHost()
    public enum HostError: Error { case activeOrCleanupRequired, notStarted, closeRequiredForTuning, tuningSetupFailed }
    private var ports = PerformanceGroupPortRegistry()
    private var delivery: PerformanceGroupDelivery?
    private var gamepads: PerformanceGroupGamepadSession?
    private var retainedTunedPorts = false
    private var groupHapticProjection:PerformanceGroupHapticProjection?
    public func groupHapticSnapshot(now:Double) -> GroupHapticSnapshot? { groupHapticProjection?.snapshot(now:now) }
    public func discardGroupHapticAttacks() { groupHapticProjection?.discardAttacks() }
    public func disableGroupHaptics() { groupHapticProjection = nil }
    private var remoteBridge: PerformanceGroupRemoteBridge?
    private var remoteRunID: UUID?
    private init() {}

    public var registeredIDs: Set<UUID> { ports.registeredIDs }
    public var localSourceStates: [SensorSource:PerformanceGroupGamepadSession.SourceState] { gamepads?.sourceStates ?? [:] }
    public var pendingCleanup: Set<UUID> {
        (delivery?.pendingCleanup ?? []).union(gamepads?.pendingCleanup ?? [])
    }
    public var pendingDisposalCount: Int { ports.pendingDisposalCount }

    private var canStart: Bool {
        (delivery?.retired ?? true) && (gamepads?.retired ?? true) && pendingCleanup.isEmpty
    }

    /// Call only after deliberate user activation and adapter readiness.
    /// A different endpoint plan requires an explicit clean close first.
    public func start(profile: PerformanceGroupProfile, allowLayering: Bool = false) throws {
        guard canStart else { throw HostError.activeOrCleanupRequired }
        guard !retainedTunedPorts else { throw HostError.closeRequiredForTuning }
        let next = try PerformanceGroupDelivery(profile:profile,allowLayering:allowLayering)
        try openPorts(profile)
        gamepads = nil
        remoteBridge = nil
        remoteRunID = nil
        delivery = next
        groupHapticProjection = nil
    }

    public static var dynamicMPEEnabled:Bool {
        #if TIHULU_GROUP_DYNAMIC_MPE_LIVE
        true
        #else
        false
        #endif
    }

    public static var dynamicMPEHapticsEnabled:Bool {
        #if TIHULU_GROUP_DYNAMIC_MPE_HAPTIC_LIVE && TIHULU_GROUP_HAPTIC_LIVE
        return dynamicMPEEnabled
        #else
        return false
        #endif
    }

    /// Only a caller owning the frozen physical controller bindings may use
    /// this entry point. The caller must provide the existing watchdog cadence.
    /// No automatic activation, device polling or handler installation here.
    public func startGamepads(profile: PerformanceGroupProfile, allowLayering: Bool = false,
                              allowSurfaces: Bool = false, allowScalars: Bool = false, allowCamera: Bool = false,
                              tuning:[UUID:PerformanceGroupTuningPlan.Specification] = [:], allowRemote:Bool = false,
                              hapticGroups:Set<UUID> = [],allowTunedHaptics:Bool = false,
                              dynamicMPE:Bool = false,confirmedDynamicMPE:Bool = false) throws {
        guard canStart else { throw HostError.activeOrCleanupRequired }
        // Never retune retained ports during another session's release tails
        // or silently switch a previously configured receiver to standard mode.
        guard !retainedTunedPorts, tuning.isEmpty || registeredIDs.isEmpty else {
            throw HostError.closeRequiredForTuning
        }
        let dynamicPlan:DynamicMPEActivationPlan?
        if dynamicMPE {
            guard Self.dynamicMPEEnabled else { throw DynamicMPEActivationPlan.AdmissionError.incompatibleMode }
            dynamicPlan = try DynamicMPEActivationPlan(profile:profile,tuning:tuning,confirmed:confirmedDynamicMPE,
                allowLayering:allowLayering,registeredIDs:registeredIDs,cleanupIDs:pendingCleanup,
                pendingDisposalCount:pendingDisposalCount,allowSurfaces:allowSurfaces,
                allowScalars:allowScalars,allowCamera:allowCamera,allowRemote:allowRemote,hapticGroups:hapticGroups,
                allowDynamicHaptics:Self.dynamicMPEHapticsEnabled)
        } else {
            guard !confirmedDynamicMPE else { throw DynamicMPEActivationPlan.AdmissionError.incompatibleMode }
            dynamicPlan = nil
        }
        var next = try PerformanceGroupGamepadSession(profile:profile,allowLayering:allowLayering,
            allowSurfaces:allowSurfaces,allowScalars:allowScalars,allowCamera:allowCamera,tuning:tuning,allowRemote:allowRemote,dynamicMPE:dynamicMPE)
        let projection:PerformanceGroupHapticProjection?
        if hapticGroups.isEmpty { projection = nil }
        else if let dynamicPlan {
            projection = try .init(preparedDynamic:dynamicPlan.preview,selected:hapticGroups)
        } else if tuning.isEmpty {
            projection = try .init(profile:profile,selected:hapticGroups)
        } else {
            guard allowTunedHaptics,!allowRemote else { throw PerformanceGroupHapticProjection.AdmissionError.invalidSelection }
            projection = try .init(profile:profile,selected:hapticGroups,preparedTuning:tuning)
        }
        try openPorts(profile)
        groupHapticProjection = nil
        delivery = nil
        remoteBridge = nil
        remoteRunID = nil
        retainedTunedPorts = !tuning.isEmpty
        let prepared = next.prepare(send:send)
        // Publish even on failure, preserving the original selector debt.
        gamepads = next
        guard prepared else { throw HostError.tuningSetupFailed }
        groupHapticProjection = projection
    }

    private func openPorts(_ profile: PerformanceGroupProfile) throws {
        let plan = try PerformanceGroupEndpointPlan(profile:profile)
        let client = try MIDIProcessClient.shared.acquire()
        try ports.open(plan,lookup:Self.lookup,create:{ entry in
            var endpoint = MIDIEndpointRef()
            let status = MIDISourceCreate(client,entry.portName as CFString,&endpoint)
            if endpoint != 0 { MIDIProcessClient.shared.registerIsolatedSource(endpoint) }
            return .init(handle:endpoint,succeeded:status == noErr)
        },assign:{ endpoint,id in
            MIDIObjectSetIntegerProperty(endpoint,kMIDIPropertyUniqueID,id) == noErr
        },dispose:Self.dispose)
    }

    private static func lookup(_ id: Int32) -> PerformanceGroupPortRegistry.Lookup {
        var object = MIDIObjectRef()
        let status = MIDIObjectFindByUniqueID(id,&object,nil)
        if status == noErr, object != 0 { return .present(object) }
        if status == kMIDIObjectNotFound { return .absent }
        return .unavailable
    }

    private static func dispose(_ endpoint: UInt32) -> Bool {
        guard MIDIEndpointDispose(endpoint) == noErr else { return false }
        MIDIProcessClient.shared.unregisterIsolatedSource(endpoint)
        return true
    }

    private func send(_ item: PerformanceGroupCommand) -> Bool {
        let accepted:Bool
        if let endpoint = ports.handle(for:item.groupID) { accepted = ChordMIDIOutput.send(item.command,endpoint:endpoint) }
        else { accepted = false }
        groupHapticProjection?.observe(item,accepted:accepted,now:ProcessInfo.processInfo.systemUptime)
        return accepted
    }

    /// Explicit listener ownership token; caller must start the established
    /// transport separately and drain it at the existing watchdog cadence.
    /// No socket, pairing secret generation or implicit Start here.
    public func beginRemoteGroupBridge() throws -> UUID {
        guard let state = gamepads,!state.retired,!state.remoteSlots.isEmpty,
              remoteBridge == nil else { throw RemoteTouchError.unavailable }
        let id = UUID()
        remoteRunID = id
        remoteBridge = PerformanceGroupRemoteBridge()
        return id
    }

    public func remoteGroupConnections(run:UUID) -> Set<UUID> {
        guard run == remoteRunID else { return [] }
        return remoteBridge?.connectionIDs ?? []
    }

    public func remoteGroupSlots(run:UUID) -> [UUID:SensorSource] {
        guard run == remoteRunID else { return [:] }
        return remoteBridge?.connectionSlots ?? [:]
    }

    public func remoteGroupLabelPreview(run:UUID,source:SensorSource) -> [String] {
        guard run == remoteRunID,remoteBridge?.ready == true,let state = gamepads else { return [] }
        return state.remoteLabelPreview(source)
    }

    public func remoteGroupReady(run:UUID) -> Bool {
        run == remoteRunID && remoteBridge?.ready == true
    }

    public func cancelRemoteGroupInvitation(run:UUID) {
        guard run == remoteRunID else { return }
        remoteBridge?.cancelInvitation()
    }

    public func issueRemoteGroupInvitation(run:UUID,secret:Data,source:SensorSource,now:Double,shareLabels:Bool = false) throws {
        guard run == remoteRunID,var bridge = remoteBridge,let state = gamepads else {
            throw RemoteTouchError.unavailable
        }
        try bridge.issue(secret:secret,source:source,now:now,session:state,shareLabels:shareLabels)
        remoteBridge = bridge
    }

    public func processRemoteGroupEvents(run:UUID,events:[RemoteHostEvent],now:Double) -> PerformanceGroupRemoteBatch {
        guard run == remoteRunID,var bridge = remoteBridge,var state = gamepads else {
            var result = PerformanceGroupRemoteBatch()
            result.actions = [.stop]
            return result
        }
        let peers = bridge.connectionIDs
        let result = bridge.process(events,now:now,
            refreshNow:{ ProcessInfo.processInfo.systemUptime },session:&state,send:send)
        if result.fault || !peers.isSubset(of:bridge.connectionIDs) { discardGroupHapticAttacks() }
        gamepads = state
        remoteBridge = bridge.stopped ? nil : bridge
        if bridge.stopped { remoteRunID = nil }
        return result
    }

    public func revokeRemoteGroupConnection(run:UUID,connection:UUID) -> PerformanceGroupRemoteBatch {
        guard run == remoteRunID,var bridge = remoteBridge,var state = gamepads else { return .init() }
        discardGroupHapticAttacks()
        let result = bridge.revoke(connection,session:&state,send:send)
        remoteBridge = bridge
        gamepads = state
        return result
    }

    public func stopRemoteGroupBridge(run:UUID) -> PerformanceGroupRemoteBatch {
        guard run == remoteRunID,var bridge = remoteBridge,var state = gamepads else { return .init() }
        discardGroupHapticAttacks()
        let result = bridge.stop(session:&state,send:send)
        gamepads = state
        remoteBridge = nil
        remoteRunID = nil
        return result
    }

    public func bindGamepad(_ source: SensorSource, now: Double) throws -> UUID {
        guard !source.isGroupRemote else { throw RemoteTouchError.unavailable }
        guard var state = gamepads else { throw HostError.notStarted }
        let token = try state.bind(source,now:now)
        gamepads = state
        return token
    }

    public func receiveGamepad(_ source: SensorSource, token: UUID, frame: GamepadFrame?, now: Double)
        -> PerformanceGroupGamepadSession.Result? {
        guard var state = gamepads else { return nil }
        let result = state.receive(source,token:token,frame:frame,now:now,send:send)
        if result.status == .lost || result.status == .admissionRejected { discardGroupHapticAttacks() }
        gamepads = state
        return result
    }

    public func receiveSurface(_ source:SensorSource, token:UUID, x:Double?, y:Double?, size:Double?,
                               hostTime:Double, now:Double) -> PerformanceGroupGamepadSession.Result? {
        guard var state = gamepads else { return nil }
        let result = state.receiveSurface(source,token:token,x:x,y:y,size:size,
                                          hostTime:hostTime,now:now,send:send)
        if result.status == .lost || result.status == .admissionRejected { discardGroupHapticAttacks() }
        gamepads = state
        return result
    }

    public func receiveScalar(_ source:SensorSource, token:UUID, value:Double?,
                              hostTime:Double, now:Double) -> PerformanceGroupGamepadSession.Result? {
        guard var state = gamepads else { return nil }
        let result = state.receiveScalar(source,token:token,value:value,hostTime:hostTime,now:now,send:send)
        if result.status == .lost || result.status == .admissionRejected { discardGroupHapticAttacks() }
        gamepads = state
        return result
    }

    public func receiveCamera(token:UUID,hand:AirHandSample?,hostTime:Double,now:Double)
        -> PerformanceGroupGamepadSession.Result? {
        guard var state = gamepads else { return nil }
        let result = state.receiveCamera(token:token,hand:hand,hostTime:hostTime,now:now,send:send)
        if result.status == .lost || result.status == .admissionRejected { discardGroupHapticAttacks() }
        gamepads = state
        return result
    }

    public func expireGamepads(now: Double) -> [PerformanceGroupDelivery.Report] {
        guard var state = gamepads else { return [] }
        let before = state.sourceStates
        let result = state.expire(now:now,send:send)
        if before != state.sourceStates { discardGroupHapticAttacks() }
        gamepads = state
        return result
    }

    public func unbindGamepad(_ source: SensorSource, token: UUID) -> [PerformanceGroupDelivery.Report] {
        unbindGroupSources([source:token])
    }

    public func unbindGroupSources(_ tokens:[SensorSource:UUID]) -> [PerformanceGroupDelivery.Report] {
        guard var state = gamepads else { return [] }
        discardGroupHapticAttacks()
        let result = state.unbindBatch(tokens,send:send)
        gamepads = state
        return result
    }

    public func connect(_ source: SensorSource, now: Double) throws -> UUID {
        guard var state = delivery else { throw HostError.notStarted }
        let id = try state.connect(source,now:now)
        delivery = state
        return id
    }

    public func frame(lease: UUID, sequence: UInt64, now: Double,
                      values: [SensorSignal:Double], releasing: Set<SensorSignal> = []) -> PerformanceGroupDelivery.Report? {
        guard var state = delivery else { return nil }
        let result = state.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing,send:send)
        delivery = state
        return result
    }

    public func disconnect(_ lease: UUID) -> PerformanceGroupDelivery.Report? {
        guard var state = delivery else { return nil }
        let result = state.disconnect(lease,send:send)
        delivery = state
        return result
    }

    public func expire(now: Double, timeout: Double) -> PerformanceGroupDelivery.Report? {
        guard var state = delivery else { return nil }
        let result = state.expire(now:now,timeout:timeout,send:send)
        delivery = state
        return result
    }

    public func stopGroup(_ id: UUID) -> PerformanceGroupDelivery.Report? {
        groupHapticProjection?.retire(id)
        if var state = gamepads {
            let result = state.stopGroup(id,send:send)
            gamepads = state
            return result
        }
        guard var state = delivery else { return nil }
        let result = state.stopGroup(id,send:send)
        delivery = state
        return result
    }

    public func panic() -> PerformanceGroupDelivery.Report? {
        // Retire the callback generation before releasing all owners.
        groupHapticProjection = nil
        remoteBridge = nil
        remoteRunID = nil
        if var state = gamepads {
            let result = state.panic(send:send)
            gamepads = state
            return result
        }
        guard var state = delivery else { return nil }
        let result = state.panic(send:send)
        delivery = state
        return result
    }

    public func retryCleanup(_ id: UUID) -> PerformanceGroupDelivery.Report? {
        if var state = gamepads {
            let result = state.retryCleanup(id,send:send)
            gamepads = state
            return result
        }
        guard var state = delivery else { return nil }
        let result = state.retryCleanup(id,send:send)
        delivery = state
        return result
    }

    /// Soft stop keeps registered ports; explicit close requires a retired,
    /// debt-free session. Never dispose the only route for a pending note-off.
    @discardableResult
    public func close() -> Bool {
        guard canStart else { return false }
        let closed = ports.close(cleanupComplete:true,dispose:Self.dispose)
        groupHapticProjection = nil
        delivery = nil
        gamepads = nil
        remoteBridge = nil
        remoteRunID = nil
        if closed { retainedTunedPorts = false }
        return closed
    }

    @discardableResult
    public func retryDisposal() -> Bool {
        let clean = ports.retryDisposal(Self.dispose)
        if clean, ports.registeredIDs.isEmpty { retainedTunedPorts = false }
        return clean
    }
}
#endif
