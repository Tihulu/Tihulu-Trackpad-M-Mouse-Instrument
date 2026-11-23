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
    case inputPort(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .client(let status): return "CoreMIDI client creation failed (OSStatus \(status))."
        case .destination(let status): return "CoreMIDI virtual destination creation failed (OSStatus \(status))."
        case .inputPort(let status): return "CoreMIDI input port creation failed (OSStatus \(status))."
        }
    }
}

/// CoreMIDI bridge for Logic Pro, DAWs and physical MIDI controllers.
/// It exposes a virtual MIDI 1.0 UMP destination named "NoSpeaker Haptic MIDI"
/// and also connects to currently available physical/software MIDI sources.
public final class MIDIHapticService: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()
    private var inputPort = MIDIPortRef()
    private var masterLevel = 0.8
    private var enabled = false
    private var callback: (@Sendable (LiveMIDIMessage) -> Void)?

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
            "NoSpeaker Haptic MIDI" as CFString,
            ._1_0,
            &newDestination
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else { stop(); throw MIDIHapticError.destination(status) }
        destination = newDestination

        var newInput = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(
            client,
            "NoSpeaker MIDI Input" as CFString,
            ._1_0,
            &newInput
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else { stop(); throw MIDIHapticError.inputPort(status) }
        inputPort = newInput
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            if source != 0 { MIDIPortConnectSource(inputPort, source, nil) }
        }
        enabled = true
    }

    public func stop() {
        lock.lock(); enabled = false; lock.unlock()
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        lock.lock(); let active = enabled; lock.unlock()
        guard active else { return }
        var packet = eventList.pointee.packet
        for _ in 0..<Int(eventList.pointee.numPackets) {
            let wordCount = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { bytes in
                let words = bytes.bindMemory(to: UInt32.self)
                for index in 0..<min(wordCount, words.count) { handleUMP(words[index]) }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func handleUMP(_ word: UInt32) {
        let messageType = Int((word >> 28) & 0xF)
        guard messageType == 0x2 else { return } // MIDI 1.0 Channel Voice UMP
        let statusByte = Int((word >> 16) & 0xFF)
        let command = statusByte & 0xF0
        let channel = statusByte & 0x0F
        let note = Int((word >> 8) & 0x7F)
        let velocity = Int(word & 0x7F)
        let isOn = command == 0x90 && velocity > 0
        let isOff = command == 0x80 || (command == 0x90 && velocity == 0)
        guard isOn || isOff else { return }
        let message = LiveMIDIMessage(channel: channel, note: note, velocity: velocity, isNoteOn: isOn)
        callback?(message)
        guard isOn else { return }

        let level = Double(velocity) / 127.0 * masterLevel
        if channel == 9, let voice = MIDIDrumMap.voice(for: note) {
            try? driver.play(HapticPatternRenderer.drumFrame(voice, velocity: level))
        } else if let frequency = try? MusicTheory.frequency(midi: note) {
            let segmentMS = max(2, (0.018 * frequency).rounded() / frequency * 1_000)
            try? driver.play(.init(tones: [.init(frequencyHz: frequency)], durationMS: segmentMS, level: level))
        }
    }
}
#endif
