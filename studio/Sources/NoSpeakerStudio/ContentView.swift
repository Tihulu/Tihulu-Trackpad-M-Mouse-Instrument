#if os(macOS)
import SwiftUI
import AppKit
import CoreGraphics
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
            .navigationTitle("TIHULU Instrument")
            .safeAreaInset(edge: .bottom) { attribution }
        } detail: {
            VStack(spacing: 0) {
                transport
                Divider()
                Group {
                    switch mode ?? .voice {
                    case .voice: VoiceModeView()
                    case .touch: TouchInstrumentView()
                    case .midiHelper: MIDIHelperView()
                    case .touchBar: TouchBarModeView()
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
        .alert("Tihulu Trackpad & M. Mouse Instrument", isPresented: Binding(
            get: { studio.lastError != nil },
            set: { if !$0 { studio.lastError = nil } }
        )) {
            Button("OK") { studio.lastError = nil }
        } message: { Text(studio.lastError ?? "Unknown error") }
        .onAppear { studio.installTouchBar() }
    }

    private var transport: some View {
        VStack(spacing: 6) {
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
          HStack(spacing: 12) {
              Toggle("Global Capture", isOn: Binding(
                  get: { studio.captureArmed },
                  set: { studio.configurePerformanceCapture(armed: $0, shortcut: studio.captureShortcut) }
              )).toggleStyle(.switch)
              PerformanceShortcutRecorder()
              Picker("Mouse Axis", selection: Binding(
                  get: { studio.magicMouseOrientation },
                  set: { studio.setMagicMouseOrientation($0) }
              )) {
                  ForEach(SurfaceOrientation.allCases) { orientation in
                      Text(orientation.rawValue).tag(orientation)
                  }
              }
              .frame(width: 170)
              .help("Rotate Magic Mouse gesture axes for all instrument and helper modes")
              Spacer()
              Label(studio.pointerCaptured ? "Pointer Captured" : "Pointer Free",
                    systemImage: studio.pointerCaptured ? "lock.fill" : "lock.open")
                  .font(.caption)
              Text("Esc = Kill Switch").foregroundStyle(.red).font(.caption.bold())
          }
          if studio.touchRunning || studio.midiHelperRunning {
              HStack(spacing: 10) {
                  Label("Sessions persist across mode changes", systemImage: "waveform.path")
                      .font(.caption)
                  if studio.touchRunning {
                      Button("Stop Touch Instrument") { studio.stopTouch() }
                          .buttonStyle(.bordered)
                  }
                  if studio.midiHelperRunning {
                      Button("Stop MIDI Helper") { studio.stopMIDIHelper() }
                          .buttonStyle(.bordered)
                  }
                  Spacer()
              }
          }
        }
        .padding(12)
    }

    private var attribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Based on os6/nospeaker").font(.caption).foregroundStyle(.secondary)
            Text("Original project by Cody Collier · MIT").font(.caption2).foregroundStyle(.tertiary)
            Text("Build \(buildLabel)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }.padding(12)
    }

    private var buildLabel: String {
        let sha = Bundle.main.object(forInfoDictionaryKey: "NoSpeakerBuildSHA") as? String ?? "unknown"
        return String(sha.prefix(12))
    }

    private func icon(for mode: StudioMode) -> String {
        switch mode {
        case .voice: "text.bubble"
        case .touch: "hand.point.up.left"
        case .midiHelper: "slider.horizontal.3"
        case .touchBar: "pianokeys"
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
    @State private var voices: [VoiceOption] = []

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
                            ForEach(voices) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                    }
                    .frame(maxWidth: 440)

                    Button("Speak on Trackpad") {
                        studio.speak(text, voice: selectedVoice.isEmpty ? nil : selectedVoice)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(voices.isEmpty)

                    Button("Stop") { studio.stopPlayback() }
                }

                if voices.isEmpty {
                    Text("No \(selectedLanguage.rawValue) voice is installed. Open System Settings → Accessibility → Spoken Content (or Read & Speak) → System Voice → Manage Voices to add languages and Enhanced/Premium voices.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text("\(selectedLanguage.rawValue) · \(voices.count) available voice option\(voices.count == 1 ? "" : "s") (macOS say + Apple AVSpeech)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Speech stays on your Mac. The app lists installed macOS voices plus optional user-installed local Piper models. Turkish female/male options appear when compatible voice files and the Piper engine are installed.")
                    .font(.callout).foregroundStyle(.secondary)
                if selectedLanguage == .turkish {
                    GroupBox("Additional Turkish Voices · Offline") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Add a local Piper model (.onnx and matching .onnx.json) to the app's Voice folder. Female and male voice models can coexist with macOS Yelda. Models are not downloaded or redistributed automatically; check each model's license.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Label(VoiceHapticService.piperIsInstalled()
                                      ? "Piper engine found" : "Piper engine not installed",
                                      systemImage: VoiceHapticService.piperIsInstalled() ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(.caption)
                                Button("Open Local Voice Folder") {
                                    let url = VoiceHapticService.piperVoiceDirectory()
                                    try? FileManager.default.createDirectory(
                                        at: url, withIntermediateDirectories: true
                                    )
                                    NSWorkspace.shared.open(url)
                                }
                                Button("Refresh Profiles") { reloadVoices() }
                            }
                        }.padding(8)
                    }
                }
                Button("Refresh Installed Voices") { reloadVoices() }
                    .buttonStyle(.bordered)
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(28)
        }
        .task { reloadVoices() }
        .onChange(of: selectedLanguage) { _ in reloadVoices() }
    }

    private func reloadVoices() {
        voices = VoiceHapticService.voiceOptions(language: selectedLanguage)
        if !voices.contains(where: { $0.id == selectedVoice }) {
            selectedVoice = voices.first?.id ?? ""
        }
    }
}

private struct TouchInstrumentView: View {
    @EnvironmentObject private var studio: StudioController

    @State private var root = 67
    @State private var scale: TouchScale = .pentatonic
    @State private var fretless = false
    @State private var zoneWidth = 1.0
    @State private var pitchSpan = 24.0
    @State private var surfaceSelection: TouchSurfaceSelection = .trackpad
    @State private var triggerMode: TouchTriggerMode = .touch
    @State private var pressThreshold = 0.5
    @State private var velocityFromPressure = false
    @State private var fixedVelocity = 100
    @State private var pressureToExpression = true
    @State private var localHapticSound = true
    @State private var multiTouch = true
    @State private var midiMode: TouchMIDIMode = .standard
    @State private var midiChannel = 1

    @State private var trackpadInstrument: SurfaceInstrumentMode = .melodic
    @State private var magicMouseInstrument: SurfaceInstrumentMode = .melodic
    @State private var trackpadOutput: SurfaceOutputRoute = .trackpadHaptic
    @State private var magicMouseOutput: SurfaceOutputRoute = .midiInstrument
    @State private var drumLayout: DrumPadLayout = .standard12
    @State private var sustainEnabled = false
    @State private var sustainTrackpadEnabled = true
    @State private var sustainTrackpadGesture: TrackpadSustainGesture = .contactThreshold
    @State private var sustainTrackpadThreshold = 0.55
    @State private var sustainTrackpadSensor: TrackpadSustainSensor = .contactSize
    @State private var sustainMouseEnabled = false
    @State private var sustainMouseGesture: MagicMouseSustainGesture = .touchHold

    private var effectivePitchSpan: Double { 24.0 / zoneWidth }

    private var mappedMIDINotes: [Int] {
        scale.mappedMIDINotes(root: root, zoneWidth: zoneWidth)
    }

    private var hasMelodic: Bool {
        (surfaceSelection.accepts(.trackpad) && trackpadInstrument == .melodic) ||
        (surfaceSelection.accepts(.magicMouse) && magicMouseInstrument == .melodic)
    }

    private var hasDrums: Bool {
        (surfaceSelection.accepts(.trackpad) && trackpadInstrument == .drums) ||
        (surfaceSelection.accepts(.magicMouse) && magicMouseInstrument == .drums)
    }

    private var rootName: String {
        (try? MusicTheory.noteName(midi: root)) ?? "MIDI \(root)"
    }

    private var configuration: TouchInstrumentConfiguration {
        .init(
            baseMIDINote: root,
            scale: scale,
            fretless: fretless,
            zoneWidth: zoneWidth,
            pitchSpanSemitones: effectivePitchSpan,
            surfaceSelection: surfaceSelection,
            triggerMode: triggerMode,
            pressThreshold: pressThreshold,
            velocityFromPressure: velocityFromPressure,
            fixedVelocity: fixedVelocity,
            pressureToExpression: pressureToExpression,
            localHapticSound: localHapticSound,
            masterLevel: studio.masterLevel,
            trackpadInstrument: trackpadInstrument,
            magicMouseInstrument: magicMouseInstrument,
            trackpadOutput: trackpadOutput,
            magicMouseOutput: magicMouseOutput,
            drumLayout: drumLayout
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Touch Instrument",
                    subtitle: "Play GM drums or melodic notes with the trackpad and Magic Mouse. Route each surface to trackpad haptics, a DAW MIDI instrument, or both."
                )

                HStack(spacing: 14) {
                    Picker("Active Surfaces", selection: $surfaceSelection) {
                        ForEach(TouchSurfaceSelection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 310)
                    .disabled(studio.touchRunning)

                    Picker("Melodic Touch", selection: $fretless) {
                        Text("Fretted").tag(false)
                        Text("Fretless").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                    .disabled(studio.touchRunning || !hasMelodic)

                    Toggle("Multi Touch", isOn: $multiTouch)
                        .toggleStyle(.switch)
                        .disabled(studio.touchRunning)

                    Spacer()

                    Button(studio.touchRunning ? "Stop Touch Instrument" : "Start Touch Instrument") {
                        if studio.touchRunning {
                            studio.stopTouch()
                        } else {
                            studio.startTouch(
                                configuration: configuration,
                                midiOut: configuration.hasMIDIOutput,
                                midiMode: midiMode,
                                multiTouch: multiTouch,
                                midiChannel: midiChannel - 1,
                                sustainSettings: .init(
                                    trackpadEnabled: sustainEnabled && sustainTrackpadEnabled,
                                    trackpadContactThreshold: sustainTrackpadThreshold,
                                    magicMouseEnabled: sustainEnabled && sustainMouseEnabled,
                                    magicMouseGesture: sustainMouseGesture,
                                    trackpadGesture: sustainTrackpadGesture,
                                    trackpadSensor: sustainTrackpadSensor
                                )
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                GroupBox("Independent Surface Instruments & Outputs") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Label("Force Touch Trackpad", systemImage: "hand.point.up.left")
                                .frame(width: 190, alignment: .leading)
                            Picker("Instrument", selection: $trackpadInstrument) {
                                ForEach(SurfaceInstrumentMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 190)
                            Picker("Output", selection: $trackpadOutput) {
                                ForEach(SurfaceOutputRoute.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 200)
                            Text(trackpadInstrument == .drums ? "GM · MIDI Ch 10" : "Melodic instrument")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Divider()

                        HStack(spacing: 14) {
                            Label("Magic Mouse", systemImage: "computermouse")
                                .frame(width: 190, alignment: .leading)
                            Picker("Instrument", selection: $magicMouseInstrument) {
                                ForEach(SurfaceInstrumentMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 190)
                            Picker("Output", selection: $magicMouseOutput) {
                                ForEach(SurfaceOutputRoute.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 200)
                            Text(magicMouseInstrument == .drums ? "GM · MIDI Ch 10" : "Melodic instrument")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Text("Magic Mouse → Trackpad Haptic drives your Mac's Force Touch motor. Magic Mouse does not contain a NoSpeaker haptic motor. Select Magic Mouse or Both above to enable its live touch notes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                .disabled(studio.touchRunning)

                HStack(spacing: 16) {
                    if hasMelodic {
                        Picker("Scale", selection: $scale) {
                            ForEach(TouchScale.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 190)
                        .disabled(studio.touchRunning)

                        Stepper("Root \(rootName)", value: $root, in: 24...96)
                            .frame(width: 170)
                            .disabled(studio.touchRunning)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(fretless ? "Pitch Size" : "Note Width")
                                Spacer()
                                Text(String(format: "%.2fx", zoneWidth)).monospacedDigit()
                            }
                            Slider(value: $zoneWidth, in: 0.5...2.0, step: 0.05)
                            if fretless {
                                Text(String(format: "%.1f semitones across surface", effectivePitchSpan))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 215)
                        .disabled(studio.touchRunning)
                    }

                    if hasDrums {
                        Picker("GM Drum Pads", selection: $drumLayout) {
                            ForEach(DrumPadLayout.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 170)
                        .disabled(studio.touchRunning)
                    }

                    Spacer()

                    Label(
                        studio.touchPreviewRunning ? "Preview Active" : "Preview Starting…",
                        systemImage: "eye.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(studio.touchPreviewRunning ? Color.green : Color.secondary)
                }

                if surfaceSelection.accepts(.trackpad) {
                    surfaceMap(
                        surface: .trackpad,
                        instrument: trackpadInstrument,
                        route: trackpadOutput
                    )
                }
                if surfaceSelection.accepts(.magicMouse) {
                    surfaceMap(
                        surface: .magicMouse,
                        instrument: magicMouseInstrument,
                        route: magicMouseOutput
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    GroupBox("Trigger") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Trigger", selection: $triggerMode) {
                                ForEach(TouchTriggerMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            if triggerMode == .press {
                                HStack {
                                    Text("Contact threshold")
                                    Slider(value: $pressThreshold, in: 0.1...1.0, step: 0.05)
                                    Text("\(Int(pressThreshold * 100))%").monospacedDigit()
                                }
                            } else {
                                Text("A light touch can trigger notes without a physical click. Recommended for Magic Mouse.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Velocity & Expression") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Velocity from Contact Size", isOn: $velocityFromPressure)
                            if !velocityFromPressure {
                                Stepper("Fixed Velocity \(fixedVelocity)", value: $fixedVelocity, in: 1...127)
                            }
                            Toggle("Contact Size → Expression", isOn: $pressureToExpression)
                        }
                        .padding(6)
                    }

                    GroupBox("Haptic Output") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Enable Local Trackpad Haptics", isOn: $localHapticSound)
                            Text("This is a master switch. Each surface's Output selector determines whether it can drive the haptic motor.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }
                }

                if configuration.hasMIDIOutput {
                    GroupBox("Logic Pro / DAW MIDI Out") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                if hasMelodic {
                                    Picker("Melodic MIDI Mode", selection: $midiMode) {
                                        ForEach(TouchMIDIMode.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 260)
                                    .disabled(studio.touchRunning)

                                    Stepper("Melodic Channel \(midiChannel)", value: $midiChannel, in: 1...16)
                                        .frame(width: 190)
                                        .disabled(studio.touchRunning || midiMode == .mpe)
                                }
                                if hasDrums {
                                    Label("Drums: GM Channel 10", systemImage: "drum")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            if hasDrums {
                                Text("Drum pads send actual GM percussion notes, not pitched scale notes. In Logic Pro, use a drum instrument/kit with matching MIDI note assignments. Channel 10 by itself does not select a drum instrument.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if hasDrums && hasMelodic && midiChannel == 10 && midiMode == .standard {
                                Text("Channel 10 is reserved for drums here. Melodic notes are automatically routed to Channel 1.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if hasMelodic && fretless && multiTouch && midiMode == .standard {
                                Text("Independent fretless multi-touch bends require MPE. Standard MIDI allows one melodic bend at a time; drums remain polyphonic on Channel 10.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if hasMelodic && midiMode == .mpe {
                                Text("MPE member channels 2–16 are allocated per finger, excluding drum Channel 10.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Touch Instrument Sustain") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Sustain", isOn: $sustainEnabled)
                            .disabled(studio.touchRunning)
                        Text("Sustain holds local haptic notes when the motor is enabled, and emits MIDI CC64 when this instrument is routed to a DAW.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if sustainEnabled {
                            SustainSettingsPanel(
                                surfaceSelection: surfaceSelection,
                                playing: studio.touchRunning,
                                active: studio.touchInstrumentSustainActive,
                                trackpadEnabled: $sustainTrackpadEnabled,
                                trackpadGesture: $sustainTrackpadGesture,
                                trackpadThreshold: $sustainTrackpadThreshold,
                                trackpadSensor: $sustainTrackpadSensor,
                                magicMouseEnabled: $sustainMouseEnabled,
                                magicMouseGesture: $sustainMouseGesture
                            )
                            .disabled(studio.touchRunning)
                        }
                    }
                    .padding(6)
                }

                CaptureSettingsPanel()

                if !studio.touchStates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Contacts").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 8) {
                            ForEach(Array(studio.touchStates.enumerated()), id: \.element.id) { index, state in
                                let drums = configuration.instrument(for: state.surface) == .drums
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("#\(index + 1) · \(state.surface.rawValue)")
                                            .font(.caption.bold())
                                        Spacer()
                                        Text(drums
                                             ? (GMDrumPads.name(for: state.quantizedMIDI) ?? "GM Drum")
                                             : ((try? MusicTheory.noteName(midi: state.quantizedMIDI)) ?? "MIDI \(state.quantizedMIDI)"))
                                            .font(.caption.monospaced())
                                    }
                                    Text("MIDI \(state.quantizedMIDI) · X \(Int(state.x * 100))% · Y \(Int(state.y * 100))%")
                                        .font(.caption2.monospaced())
                                    Text("Velocity \(state.velocity) · Contact \(Int(state.pressure * 100))%")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(9)
                                .background(.quaternary.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                }

                Text("Preview only monitors touches. Playing starts only after Start Touch Instrument; each surface's output route controls where its notes go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .task {
            studio.startTouchPreview(configuration: configuration)
        }
        .onDisappear {
            studio.stopTouchPreview()
        }
        .onChange(of: root) { _ in syncConfiguration() }
        .onChange(of: scale) { _ in syncConfiguration() }
        .onChange(of: fretless) { _ in syncConfiguration() }
        .onChange(of: zoneWidth) { _ in syncConfiguration() }
        .onChange(of: pitchSpan) { _ in syncConfiguration() }
        .onChange(of: surfaceSelection) { _ in syncConfiguration() }
        .onChange(of: triggerMode) { _ in syncConfiguration() }
        .onChange(of: pressThreshold) { _ in syncConfiguration() }
        .onChange(of: velocityFromPressure) { _ in syncConfiguration() }
        .onChange(of: fixedVelocity) { _ in syncConfiguration() }
        .onChange(of: pressureToExpression) { _ in syncConfiguration() }
        .onChange(of: localHapticSound) { _ in syncConfiguration() }
        .onChange(of: trackpadInstrument) { _ in syncConfiguration() }
        .onChange(of: magicMouseInstrument) { _ in syncConfiguration() }
        .onChange(of: trackpadOutput) { _ in syncConfiguration() }
        .onChange(of: magicMouseOutput) { _ in syncConfiguration() }
        .onChange(of: drumLayout) { _ in syncConfiguration() }
        .onChange(of: studio.masterLevel) { _ in syncConfiguration() }
    }

    @ViewBuilder
    private func surfaceMap(
        surface: TouchSurfaceKind,
        instrument: SurfaceInstrumentMode,
        route: SurfaceOutputRoute
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(surface.rawValue)
                    .font(.headline)
                Text(instrument == .drums ? "GM Drum Pads" : "Melodic Note Map")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Output: \(route.rawValue)")
                    .font(.caption.weight(.semibold))
            }

            TouchSurfaceMap(
                notes: mappedMIDINotes,
                drumPads: drumLayout.pads,
                instrument: instrument,
                rootMIDI: root,
                fretless: fretless,
                pitchSpan: effectivePitchSpan,
                states: studio.touchStates.filter { $0.surface == surface },
                active: studio.touchRunning,
                surfaceSelection: surface == .trackpad ? .trackpad : .magicMouse
            )
            .frame(height: surfaceSelection == .both ? 240 : 340)
        }
    }

    private func syncConfiguration() {
        studio.updateTouchConfiguration(configuration)
    }
}

private struct TouchSurfaceMap: View {
    let notes: [Int]
    let drumPads: [DrumPad]
    let instrument: SurfaceInstrumentMode
    let rootMIDI: Int
    let fretless: Bool
    let pitchSpan: Double
    let states: [TouchPerformanceState]
    let active: Bool
    let surfaceSelection: TouchSurfaceSelection

    var body: some View {
        GeometryReader { proxy in
            let count = max(instrument == .drums ? drumPads.count : notes.count, 1)
            let segmentWidth = proxy.size.width / CGFloat(count)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.quaternary.opacity(active ? 0.58 : 0.42))

                if instrument == .drums {
                    ForEach(drumPads.indices, id: \.self) { index in
                        let pad = drumPads[index]
                        let x = segmentWidth * (CGFloat(index) + 0.5)
                        if index > 0 {
                            Rectangle()
                                .fill(.secondary.opacity(0.24))
                                .frame(width: 1, height: proxy.size.height - 18)
                                .position(x: segmentWidth * CGFloat(index),
                                          y: proxy.size.height / 2)
                        }

                        VStack(spacing: 4) {
                            Text(pad.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.65)
                            Text("GM \(pad.midiNote)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: max(24, segmentWidth - 3))
                        .position(x: x, y: 35)
                    }
                } else if fretless {
                    ForEach(notes.indices, id: \.self) { index in
                        let note = notes[index]
                        let offset = Double(note - rootMIDI)
                        if offset >= 0, offset <= pitchSpan {
                            let x = proxy.size.width * CGFloat(offset / max(1, pitchSpan))
                            Rectangle()
                                .fill(.secondary.opacity((note - rootMIDI) % 12 == 0 ? 0.42 : 0.22))
                                .frame(width: (note - rootMIDI) % 12 == 0 ? 2 : 1,
                                       height: proxy.size.height - 20)
                                .position(x: min(proxy.size.width - 1, max(1, x)),
                                          y: proxy.size.height / 2)
                            Text((try? MusicTheory.noteName(midi: note)) ?? "\(note)")
                                .font(.caption2.monospaced())
                                .position(x: min(proxy.size.width - 22, max(22, x)), y: 18)
                        }
                    }
                } else {
                    ForEach(notes.indices, id: \.self) { index in
                        let note = notes[index]
                        let x = segmentWidth * (CGFloat(index) + 0.5)

                        if index > 0 {
                            Rectangle()
                                .fill(.secondary.opacity(0.22))
                                .frame(width: 1, height: proxy.size.height - 20)
                                .position(x: segmentWidth * CGFloat(index),
                                          y: proxy.size.height / 2)
                        }
                        VStack(spacing: 4) {
                            Text((try? MusicTheory.noteName(midi: note)) ?? "\(note)")
                                .font(.caption.monospaced().weight(.semibold))
                            Text("MIDI \(note)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: max(26, segmentWidth - 4))
                        .position(x: x, y: 28)
                    }
                }

                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    let x = min(proxy.size.width - 12,
                                max(12, CGFloat(state.x) * proxy.size.width))
                    let y = min(proxy.size.height - 12,
                                max(12, (1 - CGFloat(state.y)) * proxy.size.height))
                    let diameter = 24 + 24 * CGFloat(min(1, max(0, state.pressure)))

                    ZStack {
                        Circle()
                            .fill(state.surface == .trackpad
                                  ? Color.accentColor.opacity(0.82)
                                  : Color.cyan.opacity(0.82))
                        Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                    }
                    .frame(width: diameter, height: diameter)
                    .shadow(radius: 5)
                    .position(x: x, y: y)
                    .animation(.linear(duration: 0.025), value: x)
                    .animation(.linear(duration: 0.025), value: y)
                }

                if states.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: surfaceSelection == .magicMouse
                              ? "computermouse" : "hand.point.up.left")
                            .font(.system(size: 34))
                        Text("Preview active · touch \(surfaceSelection.rawValue) to see positions")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.65)
                }

                HStack {
                    if instrument == .drums {
                        Text("Kick / Snare")
                        Spacer()
                        Text("X = GM drum pad · lift and touch to retrigger")
                        Spacer()
                        Text("Cymbals")
                    } else {
                        Label("Lower pitch", systemImage: "arrow.left")
                        Spacer()
                        Text(fretless
                             ? "X = continuous pitch · Y = vibrato"
                             : "X = note zone · Y = vibrato")
                        Spacer()
                        Label("Higher pitch", systemImage: "arrow.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(width: proxy.size.width)
                .position(x: proxy.size.width / 2, y: proxy.size.height - 18)
            }
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(.secondary.opacity(0.24), lineWidth: 1))
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


private struct MIDIHelperView: View {
    @EnvironmentObject private var studio: StudioController

    @State private var surfaceSelection: TouchSurfaceSelection = .trackpad
    @State private var sendToDAW = true
    @State private var localSound = false
    @State private var targetChannel = 1
    @State private var pitchBendRange = 12
    @State private var vibratoCC = 1
    @State private var expressionCC = 11

    @State private var vibratoEnabled = true
    @State private var pitchBendEnabled = true
    @State private var expressionEnabled = true
    @State private var sustainEnabled = false

    @State private var trackpadSustainEnabled = true
    @State private var trackpadSustainThreshold = 0.55
    @State private var trackpadSustainSensor: TrackpadSustainSensor = .contactSize
    @State private var trackpadSustainGesture: TrackpadSustainGesture = .contactThreshold
    @State private var magicMouseSustainEnabled = false
    @State private var magicMouseSustainGesture: MagicMouseSustainGesture = .touchHold


    private var assignments: MIDIHelperAssignments {
        .init(vibrato: vibratoEnabled, pitchBend: pitchBendEnabled, expression: expressionEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "MIDI Helper",
                    subtitle: "Combine keyboard chords with independent trackpad/Magic Mouse vibrato, pitch bend, expression and sustain controls."
                )

                HStack(spacing: 14) {
                    Picker("Surface", selection: $surfaceSelection) {
                        ForEach(TouchSurfaceSelection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)

                    Spacer()

                    Button(studio.midiHelperRunning ? "Stop MIDI Helper" : "Start MIDI Helper") {
                        if studio.midiHelperRunning {
                            studio.stopMIDIHelper()
                        } else {
                            startHelper()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                GroupBox("Expression Mapping") {
                    HStack(spacing: 20) {
                        Toggle("Vibrato", isOn: $vibratoEnabled)
                        Toggle("Pitch Bend", isOn: $pitchBendEnabled)
                        Toggle("Expression", isOn: $expressionEnabled)
                        Toggle("Sustain CC64", isOn: $sustainEnabled)
                        Spacer()
                        Button("Hybrid Preset") {
                            vibratoEnabled = true
                            pitchBendEnabled = true
                            expressionEnabled = true
                        }
                    }
                    .padding(8)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HelperSurfaceMap(
                            states: studio.midiHelperStates,
                            assignments: assignments,
                            surfaceSelection: surfaceSelection,
                            active: studio.midiHelperRunning
                        )
                        .frame(minHeight: 380)

                        GroupBox("Incoming Notes / Chord") {
                            if studio.activeMIDINotes.isEmpty {
                                Text("No incoming MIDI notes. Hold a key or chord on your external keyboard / Logic MIDI input.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            } else {
                                HStack(spacing: 10) {
                                    ForEach(studio.activeMIDINotes) { note in
                                        VStack(spacing: 4) {
                                            Text((try? MusicTheory.noteName(midi: note.note)) ?? "MIDI \(note.note)")
                                                .font(.headline.monospaced())
                                            Text("Ch \(note.channel + 1) · V\(note.velocity)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .background(Color.accentColor.opacity(0.14))
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                    }
                                    Spacer()
                                }
                                .padding(6)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox("Routing") {
                            VStack(alignment: .leading, spacing: 11) {
                                Toggle("Send Helper to DAW (MIDI Out)", isOn: $sendToDAW)
                                Toggle("Local Trackpad Sound for Incoming MIDI", isOn: $localSound)
                                Stepper("Target Channel \(targetChannel)", value: $targetChannel, in: 1...16)
                                Picker("Pitch Bend Range", selection: $pitchBendRange) {
                                    Text("±2 semitones").tag(2)
                                    Text("±5 semitones").tag(5)
                                    Text("±12 semitones").tag(12)
                                    Text("±24 semitones").tag(24)
                                }
                                Stepper("Vibrato CC \(vibratoCC)", value: $vibratoCC, in: 0...127)
                                Stepper("Expression CC \(expressionCC)", value: $expressionCC, in: 0...127)
                            }
                            .padding(6)
                        }

                        if sustainEnabled {
                            SustainSettingsPanel(
                                surfaceSelection: surfaceSelection,
                                playing: studio.midiHelperRunning,
                                active: studio.midiHelperSustainActive,
                                trackpadEnabled: $trackpadSustainEnabled,
                                trackpadGesture: $trackpadSustainGesture,
                                trackpadThreshold: $trackpadSustainThreshold,
                                trackpadSensor: $trackpadSustainSensor,
                                magicMouseEnabled: $magicMouseSustainEnabled,
                                magicMouseGesture: $magicMouseSustainGesture
                            )
                        }

                        GroupBox("Gesture Mapping") {
                            VStack(alignment: .leading, spacing: 10) {
                                if pitchBendEnabled {
                                    Label("X / Horizontal → Pitch Bend", systemImage: "arrow.left.and.right")
                                }
                                if vibratoEnabled {
                                    Label("Y / Vertical → Vibrato / Modulation", systemImage: "arrow.up.and.down")
                                }
                                if expressionEnabled {
                                    Label("Contact Size → CC11 Expression", systemImage: "circle.dotted")
                                }
                                if sustainEnabled {
                                    Label("Gesture / Contact / Click → CC64 Sustain", systemImage: "hand.tap")
                                }
                                Text("Multiple fingers combine: mean X bend, highest Y vibrato, strongest contact expression. Sustain is configured independently for each surface.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }
                    }
                    .frame(width: 410)
                }

                CaptureSettingsPanel()

                Text("Preview never sends MIDI. Start the Helper before playing. Esc is the emergency stop while Studio has keyboard access; a global Esc requires macOS Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .task {
            studio.startMIDIHelperPreview(surfaceSelection: surfaceSelection)
        }
        .onDisappear {
            studio.stopMIDIHelperPreview()
        }
        .onChange(of: surfaceSelection) { _ in
            studio.updateMIDIHelperSurface(surfaceSelection)
            syncIfRunning()
        }
        .onChange(of: sendToDAW) { _ in syncIfRunning() }
        .onChange(of: localSound) { _ in syncIfRunning() }
        .onChange(of: targetChannel) { _ in syncIfRunning() }
        .onChange(of: pitchBendRange) { _ in syncIfRunning() }
        .onChange(of: vibratoCC) { _ in syncIfRunning() }
        .onChange(of: expressionCC) { _ in syncIfRunning() }
        .onChange(of: vibratoEnabled) { _ in syncIfRunning() }
        .onChange(of: pitchBendEnabled) { _ in syncIfRunning() }
        .onChange(of: expressionEnabled) { _ in syncIfRunning() }
        .onChange(of: sustainEnabled) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainEnabled) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainThreshold) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainSensor) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainGesture) { _ in syncIfRunning() }
        .onChange(of: magicMouseSustainEnabled) { _ in syncIfRunning() }
        .onChange(of: magicMouseSustainGesture) { _ in syncIfRunning() }
    }

    private func startHelper() {
        studio.startMIDIHelper(
            assignments: assignments,
            surfaceSelection: surfaceSelection,
            sendToDAW: sendToDAW,
            localSound: localSound,
            targetChannel: targetChannel - 1,
            pitchBendRange: pitchBendRange,
            vibratoCC: vibratoCC,
            expressionCC: expressionCC,
            trackpadSustainEnabled: sustainEnabled && trackpadSustainEnabled,
            trackpadSustainThreshold: trackpadSustainThreshold,
            magicMouseSustainEnabled: sustainEnabled && magicMouseSustainEnabled,
            magicMouseSustainGesture: magicMouseSustainGesture,
            trackpadSustainGesture: trackpadSustainGesture,
            trackpadSustainSensor: trackpadSustainSensor
        )
    }

    private func syncIfRunning() {
        if studio.midiHelperRunning { startHelper() }
    }

}

private struct SustainSettingsPanel: View {
    let surfaceSelection: TouchSurfaceSelection
    let playing: Bool
    let active: Bool
    @Binding var trackpadEnabled: Bool
    @Binding var trackpadGesture: TrackpadSustainGesture
    @Binding var trackpadThreshold: Double
    @Binding var trackpadSensor: TrackpadSustainSensor
    @Binding var magicMouseEnabled: Bool
    @Binding var magicMouseGesture: MagicMouseSustainGesture

    var body: some View {
        GroupBox("Sustain Pedal / MIDI CC64") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Trackpad Sustain", isOn: $trackpadEnabled)
                    .disabled(!surfaceSelection.accepts(.trackpad))
                if trackpadEnabled {
                    Picker("Trackpad Trigger", selection: $trackpadGesture) {
                        ForEach(TrackpadSustainGesture.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .disabled(!surfaceSelection.accepts(.trackpad))
                    if trackpadGesture == .contactThreshold {
                        Picker("Sensor Source", selection: $trackpadSensor) {
                            ForEach(TrackpadSustainSensor.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        HStack {
                            Text("Sensor threshold")
                                .font(.caption)
                            Slider(value: $trackpadThreshold, in: 0.05...1, step: 0.05)
                            Text("\(Int(trackpadThreshold * 100))%")
                                .font(.caption.monospaced())
                                .frame(width: 44)
                        }
                    }
                }
                Text(trackpadSensor == .contactSize
                     ? "Contact Size uses the available touch-size estimate, not calibrated Force Touch pressure."
                     : "Experimental Click Pressure reads macOS mouse-button pressure while physically clicking. A nonzero calibrated Force Touch value is not guaranteed; missing readings never activate sustain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Magic Mouse Sustain", isOn: $magicMouseEnabled)
                    .disabled(!surfaceSelection.accepts(.magicMouse))
                if magicMouseEnabled {
                    Picker("Mouse Trigger", selection: $magicMouseGesture) {
                        ForEach(MagicMouseSustainGesture.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .disabled(!surfaceSelection.accepts(.magicMouse))
                }

                HStack {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle.dashed")
                    Text(active ? "CC64 ON · Sustain Active" : "CC64 OFF · Sustain Released")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(active ? Color.green : Color.secondary)

                Text("Physical Click requires macOS Accessibility event monitoring. Because macOS does not identify the source of a global click, click sustain activates only when exactly one selected surface has an active touch. Both surfaces combine without premature CC64 release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

private struct PerformanceShortcutRecorder: View {
    @EnvironmentObject private var studio: StudioController
    @State private var recording = false
    @State private var previouslyArmed = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press your key or key combination…" :
                "Shortcut: \(studio.captureShortcut.displayName)") {
                if recording { stopRecording() }
                else { beginRecording() }
            }
            .buttonStyle(.bordered)
            if recording { Button("Cancel") { stopRecording() } }
        }
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        previouslyArmed = studio.captureArmed
        studio.configurePerformanceCapture(armed: false, shortcut: studio.captureShortcut)
        recording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                // Esc remains reserved for the emergency kill switch.
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags
            var mask: UInt64 = 0
            var prefix = ""
            if flags.contains(.control) { mask |= CGEventFlags.maskControl.rawValue; prefix += "⌃" }
            if flags.contains(.option) { mask |= CGEventFlags.maskAlternate.rawValue; prefix += "⌥" }
            if flags.contains(.shift) { mask |= CGEventFlags.maskShift.rawValue; prefix += "⇧" }
            if flags.contains(.command) { mask |= CGEventFlags.maskCommand.rawValue; prefix += "⌘" }
            let namedKeys: [UInt16: String] = [
                36:"Return",48:"Tab",49:"Space",51:"Delete",
                123:"←",124:"→",125:"↓",126:"↑",
                122:"F1",120:"F2",99:"F3",118:"F4",
                96:"F5",97:"F6",98:"F7",100:"F8",
                101:"F9",109:"F10",103:"F11",111:"F12"
            ]
            let name = namedKeys[event.keyCode] ??
                event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            studio.configurePerformanceCapture(
                armed: previouslyArmed,
                shortcut: PerformanceCaptureShortcut(
                    keyCode: Int64(event.keyCode), modifiers: mask,
                    displayName: prefix + name
                )
            )
            stopRecording(restoreCapture: false)
            return nil
        }
    }

    private func stopRecording(restoreCapture: Bool = true) {
        guard recording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        recording = false
        // Cancel/Esc or leaving the panel must not silently forget an
        // already-enabled shortcut. Recording a replacement retains its state.
        if restoreCapture && previouslyArmed {
            studio.configurePerformanceCapture(armed: true, shortcut: studio.captureShortcut)
        }
        previouslyArmed = false
    }
}

private struct CaptureSettingsPanel: View {
    @EnvironmentObject private var studio: StudioController

    var body: some View {
        GroupBox("Performance Cursor Capture · Available in Every Mode") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Toggle("Enable Global Capture", isOn: Binding(
                        get: { studio.captureArmed },
                        set: { studio.configurePerformanceCapture(
                            armed: $0, shortcut: studio.captureShortcut
                        ) }
                    ))
                    PerformanceShortcutRecorder()
                    Spacer()
                    Label(studio.pointerCaptured ? "Captured" : "Pointer Free",
                          systemImage: studio.pointerCaptured ? "lock.fill" : "lock.open")
                }
                Text(studio.captureStatus)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Record any key or key combination, then enable global capture. The shortcut toggles desktop pointer suppression in Voice, Touch, MIDI, Sequencers, Audio File, Speaker and other Studio modes. Mouse capture affects all macOS pointer devices, not only Magic Mouse. Esc triggers Panic Stop. Enable Accessibility (and if requested, Input Monitoring) in macOS System Settings. OFF by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}

private struct HelperSurfaceMap: View {
    let states: [TouchPerformanceState]
    let assignments: MIDIHelperAssignments
    let surfaceSelection: TouchSurfaceSelection
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.quaternary.opacity(active ? 0.60 : 0.42))

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width / 2, y: 22))
                    path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 22))
                    path.move(to: CGPoint(x: 22, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width - 22, y: proxy.size.height / 2))
                }
                .stroke(.secondary.opacity(0.28), lineWidth: 1)

                VStack {
                    Text(assignments.vibrato ? "Vibrato" : (assignments.pitchBend ? "Pitch Bend" : "Expression"))
                        .font(.headline)
                    Text(assignments.vibrato ? "up = more vibrato" : "touch to control")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if assignments.expression {
                        Text("Contact size = Expression")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)

                HStack {
                    if assignments.pitchBend {
                        Label("Bend −", systemImage: "arrow.left")
                    }
                    Spacer()
                    if assignments.pitchBend {
                        Label("Bend +", systemImage: "arrow.right")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    let x = min(proxy.size.width - 14, max(14, CGFloat(state.x) * proxy.size.width))
                    let y = min(proxy.size.height - 14, max(14, (1 - CGFloat(state.y)) * proxy.size.height))
                    let diameter = 28 + CGFloat(state.pressure) * 28

                    ZStack {
                        Circle()
                            .fill(state.surface == .trackpad ? Color.accentColor.opacity(0.86) : Color.cyan.opacity(0.86))
                        Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                    }
                    .frame(width: diameter, height: diameter)
                    .shadow(radius: 5)
                    .position(x: x, y: y)
                    .animation(.linear(duration: 0.025), value: x)
                    .animation(.linear(duration: 0.025), value: y)
                }

                if states.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: surfaceSelection == .magicMouse ? "computermouse" : "hand.point.up.left")
                            .font(.system(size: 34))
                        Text("Preview active · touch the \(surfaceSelection.rawValue.lowercased())")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }
}

private struct MIDIModeView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var importing = false
    private let midiType = UTType(filenameExtension: "mid") ?? .data

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: "MIDI / Logic Pro",
                subtitle: "Bidirectional MIDI for haptic playback and DAW instrument control."
            )

            GroupBox("Live MIDI In → Haptics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Virtual input: NoSpeaker Haptic MIDI In")
                        .font(.headline)
                    Text("Route a Logic Pro, Ableton Live, hardware keyboard or other MIDI source here to play the trackpad.")
                        .foregroundStyle(.secondary)
                    Text("Held keys are refreshed continuously until their matching note-off arrives, matching Touch Instrument behavior. Sustain pedal (CC64) latches released notes until pedal-up. Pitch bend follows the keyboard/DAW bend range when RPN 0,0 is sent. Mod wheel (CC1) adds vibrato; CC7 volume, CC11 expression and channel pressure are also applied.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("Touch Instrument → DAW") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Virtual output: NoSpeaker Touch MIDI Out")
                        .font(.headline)
                    Text("Choose this as the MIDI input of a software-instrument track in your DAW.")
                        .foregroundStyle(.secondary)
                    Text("Touch Instrument routes each surface independently: melodic fretted notes, continuous-pitch MPE, or GM percussion pads (Kick 36, Snare 38, Closed Hat 42, etc.) on MIDI Channel 10. Select Trackpad, Magic Mouse, or Both and choose Trackpad Haptic / MIDI Instrument / Both for each surface.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("For percussion, load a compatible drum kit in Logic Pro and align its note assignments with the GM pad layout. MIDI Channel 10 alone will not turn a piano track into a drum kit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            HStack {
                Button(studio.midiRunning ? "Disable MIDI Bridge" : "Enable MIDI Bridge") {
                    studio.midiRunning ? studio.stopMIDI() : studio.startMIDI()
                }
                .buttonStyle(.borderedProminent)

                Text(studio.lastMIDIMessage)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GroupBox("MIDI File") {
                HStack {
                    Text(studio.currentFileName)
                    Spacer()
                    Button("Open MIDI File…") { importing = true }
                }
                .padding(6)
            }

            Spacer()
        }
        .padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [midiType]) { result in
            if case .success(let url) = result {
                studio.playMIDIFile(url)
            }
        }
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

private struct TouchBarModeView: View {
    @EnvironmentObject private var studio: StudioController

    private func setProfile(_ update: (inout TouchBarProfile) -> Void) {
        var profile = studio.touchBarProfile
        update(&profile)
        studio.setTouchBarProfile(profile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Touch Bar & Tilt",
                    subtitle: "Customize a native Touch Bar performance surface or use the same MIDI controls on screen while Trackpad and Magic Mouse sessions continue."
                )

                GroupBox("Touch Bar layout · Customize simultaneous zones") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose the zones to display in your preferred order. Native Touch Bar controls appear on supported MacBook Pro models; the on-screen strip works everywhere.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(TouchBarZone.allCases) { zone in
                            HStack {
                                Toggle(zone.rawValue, isOn: Binding(
                                    get: { studio.touchBarProfile.zones.contains(zone) },
                                    set: { enabled in
                                        setProfile { profile in
                                            profile.zones.removeAll { $0 == zone }
                                            if enabled { profile.zones.append(zone) }
                                        }
                                    }
                                ))
                                Spacer()
                                if studio.touchBarProfile.zones.contains(zone) {
                                    Button("↑") {
                                        setProfile { profile in
                                            guard let index = profile.zones.firstIndex(of: zone),
                                                  index > 0 else { return }
                                            profile.zones.swapAt(index, index - 1)
                                        }
                                    }.help("Move zone left")
                                    Button("↓") {
                                        setProfile { profile in
                                            guard let index = profile.zones.firstIndex(of: zone),
                                                  index < profile.zones.count - 1 else { return }
                                            profile.zones.swapAt(index, index + 1)
                                        }
                                    }.help("Move zone right")
                                }
                            }
                        }
                        HStack {
                            Picker("Sustain behavior", selection: Binding(
                                get: { studio.touchBarProfile.sustainMode },
                                set: { value in setProfile { $0.sustainMode = value } }
                            )) {
                                ForEach(TouchBarSustainMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }.frame(width: 220)
                            Picker("MIDI channel", selection: Binding(
                                get: { studio.touchBarProfile.channel },
                                set: { value in setProfile { $0.channel = value } }
                            )) {
                                ForEach(0..<16, id: \.self) { channel in
                                    Text("Channel \(channel + 1)").tag(channel)
                                }
                            }.frame(width: 220)
                            Stepper("Base Note \(studio.touchBarProfile.baseNote)",
                                    value: Binding(
                                        get: { studio.touchBarProfile.baseNote },
                                        set: { value in setProfile { $0.baseNote = value } }
                                    ), in: 0...115)
                            Spacer()
                        }
                    }.padding(8)
                }

                GroupBox("Live performance strip · On-screen Touch Bar") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(studio.touchBarProfile.zones) { zone in
                            switch zone {
                            case .keys:
                                HStack(spacing: 4) {
                                    Text("Piano").frame(width: 115, alignment: .leading)
                                    ForEach(0..<8, id: \.self) { index in
                                        TouchBarNotePad(
                                            note: studio.touchBarProfile.baseNote + index,
                                            label: ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G"][index]
                                        )
                                    }
                                }
                            case .sustain:
                                HStack {
                                    Text("Sustain").frame(width: 115, alignment: .leading)
                                    if studio.touchBarProfile.sustainMode == .hold {
                                        Button(studio.touchBarSustainOn ? "HOLDING" : "Press & hold") {}
                                            .onLongPressGesture(
                                                minimumDuration: 0,
                                                pressing: { studio.touchBarSustainPressed($0) },
                                                perform: {}
                                            )
                                    } else {
                                        Button(studio.touchBarSustainOn ? "Sustain ON" : "Sustain OFF") {
                                            studio.touchBarSustainPressed(true)
                                        }
                                    }
                                }
                            case .fretless, .pitchBend, .vibrato, .expression, .filter:
                                TouchBarSliderPad(zone: zone)
                            }
                        }
                        Text("Slides send live MIDI CC/bend to the same virtual MIDI output used by Logic. Keys send Note On/Off; Touch/Helper sessions remain independent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }

                GroupBox("Screen hinge as an instrument · Calibration simulator") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Map screen opening to filter, expression, vibrato or pitch bend. Live hardware detection is experimental, manual-only and may be unsupported on Touch Bar MacBooks; use the simulator if no compatible sensor is available.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Enable Live Hinge Angle Sensor (Experimental)", isOn: Binding(
                            get: { studio.liveHingeEnabled },
                            set: { studio.enableLiveHinge($0) }
                        ))
                        Text(studio.hingeSensorStatus)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Picker("MIDI mapping", selection: Binding(
                            get: { studio.touchBarProfile.tiltTarget },
                            set: { value in setProfile { $0.tiltTarget = value } }
                        )) {
                            ForEach(TiltMIDITarget.allCases) { target in
                                Text(target.rawValue).tag(target)
                            }
                        }.frame(width: 240)
                        HStack {
                            Text("Lid angle")
                            Slider(value: Binding(
                                get: { studio.simulatedHingeAngle },
                                set: { studio.applySimulatedHingeAngle($0) }
                            ), in: 5...175)
                            .disabled(studio.liveHingeEnabled)
                            Text("\(Int(studio.simulatedHingeAngle))°")
                                .monospacedDigit().frame(width: 60)
                        }
                        HStack {
                            Stepper("Closed / Min \(Int(studio.touchBarProfile.tiltMinDegrees))°",
                                    value: Binding(
                                        get: { studio.touchBarProfile.tiltMinDegrees },
                                        set: { value in setProfile { $0.tiltMinDegrees = value } }
                                    ), in: 5...170, step: 5)
                            Stepper("Open / Max \(Int(studio.touchBarProfile.tiltMaxDegrees))°",
                                    value: Binding(
                                        get: { studio.touchBarProfile.tiltMaxDegrees },
                                        set: { value in setProfile { $0.tiltMaxDegrees = value } }
                                    ), in: 10...175, step: 5)
                        }
                        Button("Return MIDI to Neutral") {
                            studio.applySimulatedHingeAngle((
                                studio.touchBarProfile.tiltMinDegrees +
                                studio.touchBarProfile.tiltMaxDegrees
                            ) / 2)
                        }
                    }.padding(8)
                }
                Text("Safety: Hinge sensor is explicitly opt-in and uses a read-only, undocumented HID report on compatible MacBooks. An unavailable sensor never starts monitoring. The app does not move the display, modify sleep settings, or send any telemetry.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}

private struct TouchBarSliderPad: View {
    @EnvironmentObject private var studio: StudioController
    let zone: TouchBarZone
    @State private var value = 0.5

    var body: some View {
        HStack {
            Text(zone.rawValue).frame(width: 115, alignment: .leading)
            Slider(value: $value, in: 0...1, onEditingChanged: { editing in
                if !editing && (zone == .pitchBend || zone == .fretless) {
                    value = 0.5
                    studio.touchBarValue(zone, normalized: 0.5)
                }
            })
            .onChange(of: value) { newValue in
                studio.touchBarValue(zone, normalized: newValue)
            }
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 60)
        }
    }
}

private struct TouchBarNotePad: View {
    @EnvironmentObject private var studio: StudioController
    let note: Int
    let label: String
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isDown ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isDown {
                        isDown = true
                        studio.touchBarKey(note, pressed: true)
                    }
                }
                .onEnded { _ in
                    if isDown {
                        isDown = false
                        studio.touchBarKey(note, pressed: false)
                    }
                }
            )
            .onDisappear {
                if isDown { studio.touchBarKey(note, pressed: false) }
            }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var frequency = 1_000.0
    @State private var captureReport = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Diagnostics",
                    subtitle: "Inspect the haptic engine and diagnose global performance capture without recording typed content."
                )
                GroupBox("Global Capture · Read-only diagnostics") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Test procedure: (1) Record a shortcut and turn on Global Capture in the top bar. (2) Refresh below. (3) Switch to another app, press your shortcut twice, and move the pointer. (4) Return and refresh. The key-down and shortcut-match counters should increase. A captured pointer should stop moving until released.")
                            .font(.callout)
                        HStack(spacing: 10) {
                            Button("Refresh Snapshot") {
                                captureReport = studio.globalCaptureDiagnosticReport()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Copy Report") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(captureReport, forType: .string)
                            }
                            .disabled(captureReport.isEmpty)
                            Spacer()
                            Label("No keystroke logging", systemImage: "lock.shield")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Text(captureReport.isEmpty ? "Press Refresh Snapshot to inspect capture." : captureReport)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .padding(8)
                }
                GroupBox("Haptic motor diagnostics") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Slider(value: $frequency, in: 98...3_951)
                            Text("\(Int(frequency)) Hz").monospacedDigit().frame(width: 75)
                            Button("Test Tone") { studio.testTone(frequency: frequency) }
                        }
                        HStack {
                            Button("100 Hz → 4 kHz Sweep") { studio.sweep() }
                            Button("Reconnect Trackpad") { studio.reconnect() }
                        }
                        Text("The motor frequency range follows the original nospeaker measurements. Resonance and loudness vary between trackpads.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .padding(28)
        }
        .onAppear { captureReport = studio.globalCaptureDiagnosticReport() }
    }
}

private struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "About Tihulu Trackpad & M. Mouse Instrument", subtitle: "A native macOS expressive trackpad, Magic Mouse and haptic MIDI workstation.")
                GroupBox("Upstream credit") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tihulu Trackpad & M. Mouse Instrument is based on nospeaker by Cody Collier (os6).").font(.headline)
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
