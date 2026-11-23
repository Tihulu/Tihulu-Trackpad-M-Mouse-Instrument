#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import NoSpeakerCore
import NoSpeakerMac

struct ContentView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var mode: StudioMode? = .voice

    var body: some View {
        NavigationSplitView {
            List(StudioMode.allCases, selection: $mode) { item in
                Label(item.rawValue, systemImage: icon(for: item)).tag(item)
            }
            .navigationTitle("NoSpeaker Studio")
            .safeAreaInset(edge: .bottom) { attribution }
        } detail: {
            VStack(spacing: 0) {
                transport
                Divider()
                Group {
                    switch mode ?? .voice {
                    case .voice: VoiceModeView()
                    case .touch: TouchInstrumentView()
                    case .notes: NoteSequencerView()
                    case .drums: DrumSequencerView()
                    case .midi: MIDIModeView()
                    case .audio: AudioFileModeView()
                    case .speaker: SpeakerModeView()
                    case .diagnostics: DiagnosticsView()
                    case .about: AboutView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("NoSpeaker Studio", isPresented: Binding(
            get: { studio.lastError != nil },
            set: { if !$0 { studio.lastError = nil } }
        )) {
            Button("OK") { studio.lastError = nil }
        } message: { Text(studio.lastError ?? "Unknown error") }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Circle().fill(studio.engineReady ? Color.green : Color.orange).frame(width: 9, height: 9)
            Text(studio.engineStatus).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if !studio.engineReady { Button("Reconnect") { studio.reconnect() } }
            Spacer()
            Text("BPM")
            TextField("BPM", value: $studio.bpm, format: .number.precision(.fractionLength(0)))
                .frame(width: 58).textFieldStyle(.roundedBorder)
            Button("Stop") { studio.stopPlayback() }.keyboardShortcut(".", modifiers: .command)
            Button {
                studio.panicStop()
            } label: {
                HStack(spacing: 7) {
                    Text("PANIC STOP")
                    Text("Esc")
                        .font(.caption2.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .keyboardShortcut(.escape, modifiers: [])
            Slider(value: $studio.masterLevel, in: 0...1) { Text("Master") }.frame(width: 130)
            Text("\(Int(studio.masterLevel * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .padding(12)
    }

    private var attribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Based on os6/nospeaker").font(.caption).foregroundStyle(.secondary)
            Text("Original project by Cody Collier · MIT").font(.caption2).foregroundStyle(.tertiary)
        }.padding(12)
    }

    private func icon(for mode: StudioMode) -> String {
        switch mode {
        case .voice: "text.bubble"
        case .touch: "hand.point.up.left"
        case .notes: "pianokeys"
        case .drums: "circle.grid.cross"
        case .midi: "cable.connector"
        case .audio: "waveform"
        case .speaker: "speaker.wave.2"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VoiceModeView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var text = "Hello from the trackpad."
    @State private var selectedLanguage: VoiceLanguage = .english
    @State private var selectedVoice = ""
    @State private var voices: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Voice", subtitle: "Type anything and render it through the trackpad using the upstream LPC/formant voice method.")
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
                    .padding(8).background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 16) {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(VoiceLanguage.allCases) { language in
                            Text(language.rawValue).tag(language)
                        }
                    }
                    .frame(width: 190)

                    Picker("Voice", selection: $selectedVoice) {
                        if voices.isEmpty {
                            Text("No installed voice").tag("")
                        } else {
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .frame(maxWidth: 320)

                    Button("Speak on Trackpad") {
                        studio.speak(text, voice: selectedVoice.isEmpty ? nil : selectedVoice)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(voices.isEmpty)

                    Button("Stop") { studio.stopPlayback() }
                }

                if voices.isEmpty {
                    Text("No \(selectedLanguage.rawValue) macOS voice is installed. Add one in System Settings → Accessibility → Spoken Content → System Voice.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text("\(selectedLanguage.rawValue) · \(voices.count) installed voice\(voices.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Speech is rendered locally with macOS `say`, analyzed locally, and sent to the haptic motor. No cloud service is required.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(28)
        }
        .task { reloadVoices() }
        .onChange(of: selectedLanguage) { _ in reloadVoices() }
    }

    private func reloadVoices() {
        voices = VoiceHapticService.installedVoices(language: selectedLanguage)
        if !voices.contains(selectedVoice) {
            selectedVoice = voices.first ?? ""
        }
    }
}

private struct TouchInstrumentView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var root = 67
    @State private var scale: TouchScale = .pentatonic

    private var mappedMIDINotes: [Int] {
        scale.intervals.map { min(127, max(0, root + $0)) }
    }

    private var rootName: String {
        (try? MusicTheory.noteName(midi: root)) ?? "MIDI \(root)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Touch Instrument", subtitle: "Slide horizontally for pitch, vertically for vibrato, and use contact size for level.")
            HStack(spacing: 24) {
                Picker("Scale", selection: $scale) { ForEach(TouchScale.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 220)
                Stepper("Root \(rootName)", value: $root, in: 36...84).frame(width: 190)
                Button(studio.touchRunning ? "Stop Touch Instrument" : "Start Touch Instrument") {
                    studio.touchRunning ? studio.stopTouch() : studio.startTouch(rootMIDI: root, scale: scale)
                }.buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(rootName) · \(scale.rawValue)")
                        .font(.headline)
                    Spacer()
                    Text("\(mappedMIDINotes.count) touch zones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScaleTrackpadMap(
                    notes: mappedMIDINotes,
                    rootMIDI: root,
                    active: studio.touchRunning,
                    contact: studio.touchContact
                )
                    .frame(minHeight: 300)

                HStack {
                    Label("Lower notes", systemImage: "arrow.left")
                    Spacer()
                    Text("Move upward anywhere for more vibrato")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Higher notes", systemImage: "arrow.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }.padding(28)
    }
}

private struct ScaleTrackpadMap: View {
    let notes: [Int]
    let rootMIDI: Int
    let active: Bool
    let contact: TrackpadContact

    var body: some View {
        GeometryReader { proxy in
            let count = max(notes.count, 1)
            let segmentWidth = proxy.size.width / CGFloat(count)
            let normalizedX = min(0.9999, max(0, CGFloat(contact.x)))
            let normalizedY = min(1, max(0, CGFloat(contact.y)))
            let activeIndex = contact.isDown ? min(count - 1, Int(normalizedX * CGFloat(count))) : -1
            let contactX = min(proxy.size.width - 10, max(10, normalizedX * proxy.size.width))
            let contactY = min(proxy.size.height - 10, max(10, (1 - normalizedY) * proxy.size.height))
            let contactDiameter = 18 + 18 * min(1, max(0, CGFloat(contact.size)))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.quaternary.opacity(active ? 0.58 : 0.42))

                ForEach(notes.indices, id: \.self) { index in
                    let note = notes[index]
                    let isRootClass = (note - rootMIDI) % 12 == 0
                    let name = (try? MusicTheory.noteName(midi: note)) ?? "\(note)"
                    let x = segmentWidth * (CGFloat(index) + 0.5)

                    if contact.isDown, index == activeIndex {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: max(1, segmentWidth), height: proxy.size.height - 4)
                            .position(x: x, y: proxy.size.height / 2)
                    }

                    if index > 0 {
                        Rectangle()
                            .fill(.secondary.opacity(0.22))
                            .frame(width: 1, height: proxy.size.height - 24)
                            .position(x: segmentWidth * CGFloat(index), y: proxy.size.height / 2)
                    }

                    VStack(spacing: 6) {
                        Text(name)
                            .font(notes.count > 18 ? .system(size: 10, weight: isRootClass ? .bold : .medium, design: .monospaced) : .system(size: 12, weight: isRootClass ? .bold : .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)

                        Text("MIDI \(note)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isRootClass {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.vertical, 18)
                    .frame(width: max(22, segmentWidth - 4), height: proxy.size.height - 8)
                    .position(x: x, y: proxy.size.height / 2)
                }

                if active, contact.isDown {
                    Circle()
                        .fill(Color.accentColor.opacity(0.88))
                        .frame(width: contactDiameter, height: contactDiameter)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.9), lineWidth: 2)
                        )
                        .shadow(radius: 4)
                        .position(x: contactX, y: contactY)
                        .animation(.linear(duration: 0.035), value: contactX)
                        .animation(.linear(duration: 0.035), value: contactY)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 8) {
                    Image(systemName: active ? "hand.point.up.left.fill" : "hand.point.up.left")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(active && contact.isDown
                         ? "Live touch · \((try? MusicTheory.noteName(midi: notes[activeIndex])) ?? "MIDI \(notes[activeIndex])")"
                         : (active ? "Play these zones on the physical trackpad" : "Start Touch Instrument, then use the matching physical zones"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.72)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.secondary.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

private struct NoteSequencerView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var notes: [Int?] = Array(repeating: nil, count: 16)
    @State private var selectedMIDI = 72
    @State private var velocity = 0.85
    @State private var loop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Note Sequencer", subtitle: "Build a 16-step melody and play it directly through the haptic motor.")
            HStack {
                Stepper("Selected note: \((try? MusicTheory.noteName(midi: selectedMIDI)) ?? "-")", value: $selectedMIDI, in: 48...95)
                Slider(value: $velocity, in: 0.1...1) { Text("Velocity") }.frame(width: 180)
                Toggle("Loop", isOn: $loop).toggleStyle(.switch)
                Spacer()
                Button("Play Pattern") { play() }.buttonStyle(.borderedProminent)
                Button("Clear") { notes = Array(repeating: nil, count: 16) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(0..<16, id: \.self) { index in
                    Button {
                        notes[index] = notes[index] == nil ? selectedMIDI : nil
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                            Text(notes[index].flatMap { try? MusicTheory.noteName(midi: $0) } ?? "—").font(.headline.monospaced())
                        }.frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(notes[index] == nil ? .gray.opacity(0.32) : .accentColor)
                    .contextMenu {
                        Button("Set selected note") { notes[index] = selectedMIDI }
                        Button("Transpose +12") { if let n = notes[index] { notes[index] = min(127, n + 12) } }
                        Button("Transpose -12") { if let n = notes[index] { notes[index] = max(0, n - 12) } }
                        Button("Clear") { notes[index] = nil }
                    }
                }
            }
            Spacer()
        }.padding(28)
    }

    private func play() {
        let steps = notes.enumerated().compactMap { index, note -> NoteStep? in
            guard let note else { return nil }
            return NoteStep(index: index, midi: note, velocity: velocity, gate: 0.8)
        }
        studio.playNotes(steps, loop: loop)
    }
}

private struct DrumSequencerView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var active: Set<String> = ["kick:0","kick:8","snare:4","snare:12","closedHat:0","closedHat:2","closedHat:4","closedHat:6","closedHat:8","closedHat:10","closedHat:12","closedHat:14"]
    @State private var loop = false
    private let voices: [DrumVoice] = [.kick, .snare, .closedHat, .openHat, .clap, .tom]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Drum Sequencer", subtitle: "Sequence haptic kick, snare, hats, clap and tom voices.")
            HStack { Toggle("Loop", isOn: $loop); Spacer(); Button("Play Pattern") { play() }.buttonStyle(.borderedProminent); Button("Clear") { active.removeAll() } }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(voices, id: \.self) { voice in
                        HStack(spacing: 7) {
                            Text(label(voice)).frame(width: 82, alignment: .leading)
                            ForEach(0..<16, id: \.self) { step in
                                let key = "\(voice.rawValue):\(step)"
                                Button("\(step + 1)") { if active.contains(key) { active.remove(key) } else { active.insert(key) } }
                                    .buttonStyle(.borderedProminent)
                                    .tint(active.contains(key) ? .accentColor : .gray.opacity(0.28))
                                    .frame(width: 38)
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
            Spacer()
        }.padding(28)
    }

    private func label(_ voice: DrumVoice) -> String {
        switch voice {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .closedHat: return "Closed Hat"
        case .openHat: return "Open Hat"
        case .clap: return "Clap"
        case .tom: return "Tom"
        }
    }
    private func play() {
        let hits = voices.flatMap { voice in (0..<16).compactMap { active.contains("\(voice.rawValue):\($0)") ? DrumStep(index: $0, voice: voice, velocity: 0.9) : nil } }
        studio.playDrums(hits, loop: loop)
    }
}

private struct MIDIModeView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var importing = false
    private let midiType = UTType(filenameExtension: "mid") ?? .data

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "MIDI / Logic Pro", subtitle: "Play live MIDI through the trackpad or drop a Standard MIDI File.")
            GroupBox("Live MIDI") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Virtual destination: NoSpeaker Haptic MIDI").font(.headline)
                    Text("In Logic Pro, route a MIDI track to this destination. MIDI channel 10 is mapped to haptic drums.").foregroundStyle(.secondary)
                    HStack {
                        Button(studio.midiRunning ? "Disable MIDI Bridge" : "Enable MIDI Bridge") { studio.midiRunning ? studio.stopMIDI() : studio.startMIDI() }.buttonStyle(.borderedProminent)
                        Text(studio.lastMIDIMessage).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
            GroupBox("MIDI File") {
                HStack { Text(studio.currentFileName); Spacer(); Button("Open MIDI File…") { importing = true } }
                    .padding(6)
            }
            Spacer()
        }.padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [midiType]) { result in if case .success(let url) = result { studio.playMIDIFile(url) } }
    }
}

private struct AudioFileModeView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Audio File", subtitle: "Drop a song or recording and reinterpret it as haptic sound.")
            Picker("Conversion Profile", selection: $studio.activeProfile) { ForEach(AudioHapticProfile.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            DropFileView(title: "Drop audio or MIDI here", subtitle: "WAV · AIFF · MP3 · M4A · MIDI") { studio.handleDroppedFile($0) }
            HStack { Text(studio.currentFileName).foregroundStyle(.secondary); Spacer(); Button("Open Audio File…") { importing = true }; Button("Stop") { studio.stopPlayback() } }
            Spacer()
        }.padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in if case .success(let url) = result { studio.playAudioFile(url) } }
    }
}

private struct SpeakerModeView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Trackpad Speaker", subtitle: "Use the Force Touch motor as an experimental, quiet haptic speaker.")
            Picker("Speaker Profile", selection: $studio.activeProfile) { ForEach(AudioHapticProfile.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            GroupBox("Play a file as haptic audio") {
                HStack { Text(studio.currentFileName); Spacer(); Button("Choose Audio…") { importing = true } }.padding(6)
            }
            GroupBox("Live system audio") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture macOS system audio with ScreenCaptureKit and convert it to haptic output in real time.")
                    Text("macOS will request Screen Recording permission. This mode does not install a virtual audio driver and does not appear as a selectable physical output device in Sound Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(studio.systemAudioRunning ? "Stop System Audio" : "Start System Audio → Trackpad") {
                        studio.systemAudioRunning ? studio.stopSystemAudio() : studio.startSystemAudio()
                    }.buttonStyle(.borderedProminent)
                }.padding(6)
            }
            Text("The trackpad actuator is not a hi-fi loudspeaker. Studio keeps the original project's normal motor level ceiling and prioritizes safety over loudness.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in if case .success(let url) = result { studio.playAudioFile(url) } }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var frequency = 1_000.0
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Diagnostics", subtitle: "Test the haptic path without running a musical mode.")
            HStack { Slider(value: $frequency, in: 98...3_951); Text("\(Int(frequency)) Hz").monospacedDigit().frame(width: 70); Button("Test Tone") { studio.testTone(frequency: frequency) } }
            HStack { Button("100 Hz → 4 kHz Sweep") { studio.sweep() }.buttonStyle(.borderedProminent); Button("Reconnect Trackpad") { studio.reconnect() } }
            Text("Usable range follows the measurements published by the original nospeaker project. Resonance and loudness vary between trackpads.").foregroundStyle(.secondary)
            Spacer()
        }.padding(28)
    }
}

private struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "About NoSpeaker Studio", subtitle: "A native macOS haptic-audio workstation built from the nospeaker experiment.")
                GroupBox("Upstream credit") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NoSpeaker Studio is based on nospeaker by Cody Collier (os6).").font(.headline)
                        Text("Upstream: https://github.com/os6/nospeaker")
                        Text("Initial compatibility baseline: nospeaker v1.0 · 64c5fbf493fab0a79382c8e101de8d80083b0d5c")
                        Text("License: MIT")
                        Text("The original trackpad-audio technique, private MultitouchSupport actuator path, touch record interpretation and LPC/formant voice approach are credited to the upstream project. Downstream Studio features do not imply endorsement by the original author.")
                            .foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("Studio additions") {
                    Text("Independent Voice, Touch Instrument, Note Sequencer, Drum Sequencer, CoreMIDI / Logic Pro bridge, MIDI-file import, audio drag-and-drop, live system-audio haptic speaker mode, safety controls and a native SwiftUI interface.")
                        .padding(6)
                }
                Spacer()
            }.padding(28)
        }
    }
}
#endif
