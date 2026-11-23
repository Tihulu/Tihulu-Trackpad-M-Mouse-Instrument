#if os(macOS)
import Foundation
import SwiftUI
import NoSpeakerCore
import NoSpeakerMac

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
    @Published var touchContact = TrackpadContact()
    @Published var systemAudioRunning = false
    @Published var lastMIDIMessage = "No MIDI received yet"
    @Published var currentFileName = "No file loaded"
    @Published var activeProfile: AudioHapticProfile = .fullMix

    private var driver: HapticTrackpadDriver?
    private var playback: HapticPlaybackEngine?
    private var touch: TouchInstrumentService?
    private var midi: MIDIHapticService?
    private var systemAudio: SystemAudioHapticCapture?

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
        playback?.stop(closeDriver: true)
        touch?.stop()
        midi?.stop()
        Task { await systemAudio?.stop() }
        isPlaying = false
        touchRunning = false
        touchContact = TrackpadContact()
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

    func startTouch(rootMIDI: Int, scale: TouchScale, fretless: Bool = false, midiOut: Bool = false) {
        guard requireEngine(), let touch else { return }

        if midiOut, !midiRunning {
            startMIDI()
        }

        do {
            try touch.start(
                baseMIDINote: rootMIDI,
                scale: scale,
                fretless: fretless,
                masterLevel: masterLevel
            ) { [weak self] performance in
                Task { @MainActor in
                    guard let self else { return }
                    self.touchContact = performance.contact
                    if midiOut {
                        self.midi?.sendTouch(
                            continuousMIDI: performance.continuousMIDI,
                            quantizedMIDI: performance.quantizedMIDI,
                            velocity: performance.velocity,
                            isDown: performance.contact.isDown,
                            fretless: fretless,
                            rootMIDI: rootMIDI
                        )
                    }
                }
            }
            touchContact = TrackpadContact()
            touchRunning = true
            engineStatus = midiOut
                ? (fretless ? "Touch Instrument active · Fretless MIDI Out" : "Touch Instrument active · MIDI Out")
                : (fretless ? "Touch Instrument active · Fretless" : "Touch Instrument active")
        } catch { fail(error) }
    }

    func stopTouch() {
        touch?.stop()
        midi?.endTouchOutput()
        touchContact = TrackpadContact()
        touchRunning = false
        engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
    }

    func startMIDI() {
        guard requireEngine(), let midi else { return }
        do {
            try midi.start(masterLevel: masterLevel) { [weak self] message in
                Task { @MainActor in
                    self?.lastMIDIMessage = "Ch \(message.channel + 1) · Note \(message.note) · Velocity \(message.velocity) · \(message.isNoteOn ? "On" : "Off")"
                }
            }
            midiRunning = true
            engineStatus = "MIDI bridge active · Haptic MIDI In + Touch MIDI Out"
        } catch { fail(error) }
    }

    func stopMIDI() {
        midi?.endTouchOutput()
        midi?.stop()
        midiRunning = false
        engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus
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
