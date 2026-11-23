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

public enum MIDIHapticError: LocalizedError {
    case client(OSStatus)
    case destination(OSStatus)
    case source(OSStatus)
    case inputPort(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .client(let status): return "CoreMIDI client creation failed (OSStatus \(status))."
        case .destination(let status): return "CoreMIDI virtual input creation failed (OSStatus \(status))."
        case .source(let status): return "CoreMIDI virtual output creation failed (OSStatus \(status))."
        case .inputPort(let status): return "CoreMIDI input port creation failed (OSStatus \(status))."
        }
    }
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
        var keyDown: Bool
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
    private var renderTimer: DispatchSourceTimer?

    private var touchOutputNote: Int?
    private var touchOutputChannel = 0
    private var touchOutputFretless = false

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    deinit { stop() }

    public func start(masterLevel: Double, onMessage: (@Sendable (LiveMIDIMessage) -> Void)? = nil) throws {
        stop()
        self.masterLevel = masterLevel
        self.callback = onMessage

        var newClient = MIDIClientRef()
        var status = MIDIClientCreateWithBlock("NoSpeaker Studio" as CFString, &newClient) { _ in }
        guard status == noErr else { throw MIDIHapticError.client(status) }
        client = newClient

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

        lock.lock()
        enabled = true
        activeNotes.removeAll()
        sustainByChannel.removeAll()
        pitchBendByChannel.removeAll()
        lock.unlock()
        startRenderTimer()
    }

    public func stop() {
        endTouchOutput()

        lock.lock()
        enabled = false
        activeNotes.removeAll()
        sustainByChannel.removeAll()
        pitchBendByChannel.removeAll()
        lock.unlock()

        renderTimer?.cancel()
        renderTimer = nil

        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource); virtualSource = 0 }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
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
        timer.schedule(deadline: .now(), repeating: .milliseconds(18), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.renderActiveNotes() }
        renderTimer = timer
        timer.resume()
    }

    private func renderActiveNotes() {
        lock.lock()
        let active = enabled
        let notes = Array(activeNotes.prefix(6))
        let bends = pitchBendByChannel
        let levelScale = masterLevel
        lock.unlock()
        guard active, !notes.isEmpty else { return }

        var tones: [HapticTone] = []
        var combinedLevel = 0.0

        for (key, state) in notes {
            guard let frequency = try? MusicTheory.frequency(midi: key.note) else { continue }
            let bend14 = bends[key.channel] ?? 8192
            let bendSemitones = (Double(bend14) - 8192.0) / 8192.0 * 2.0
            let bentFrequency = frequency * pow(2.0, bendSemitones / 12.0)
            tones.append(.init(frequencyHz: bentFrequency))
            combinedLevel = max(combinedLevel, Double(state.velocity) / 127.0)
        }

        guard !tones.isEmpty else { return }
        try? driver.play(.init(
            tones: tones,
            durationMS: 20,
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
        activeNotes[key] = ActiveNote(velocity: velocity, keyDown: true)
        lock.unlock()
        callback?(.init(channel: channel, note: note, velocity: velocity, isNoteOn: true))
    }

    private func noteOff(channel: Int, note: Int, velocity: Int) {
        let key = NoteKey(channel: channel, note: note)
        lock.lock()
        if sustainByChannel[channel] == true, var state = activeNotes[key] {
            state.keyDown = false
            activeNotes[key] = state
        } else {
            activeNotes.removeValue(forKey: key)
        }
        lock.unlock()
        callback?(.init(channel: channel, note: note, velocity: velocity, isNoteOn: false))
    }

    private func controlChange(channel: Int, controller: Int, value: Int) {
        guard controller == 64 else { return }
        let sustainOn = value >= 64

        lock.lock()
        sustainByChannel[channel] = sustainOn
        if !sustainOn {
            activeNotes = activeNotes.filter { key, state in
                key.channel != channel || state.keyDown
            }
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
