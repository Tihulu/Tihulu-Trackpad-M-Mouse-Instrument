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
                    case .midiHelper: MIDIHelperView()
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
            pitchSpanSemitones: pitchSpan,
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
                                midiChannel: midiChannel - 1
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

                        if fretless {
                            Picker("Pitch Span", selection: $pitchSpan) {
                                Text("±2 st").tag(4.0)
                                Text("±5 st").tag(10.0)
                                Text("±12 st / 2 oct").tag(24.0)
                            }
                            .frame(width: 190)
                            .disabled(studio.touchRunning)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Note Width")
                                    Spacer()
                                    Text(String(format: "%.2fx", zoneWidth)).monospacedDigit()
                                }
                                Slider(value: $zoneWidth, in: 0.5...2.0, step: 0.05)
                            }
                            .frame(width: 180)
                            .disabled(studio.touchRunning)
                        }
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
                pitchSpan: pitchSpan,
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
    @State private var mode: MIDIHelperMode = .hybrid
    @State private var sendToDAW = true
    @State private var localSound = false
    @State private var targetChannel = 1
    @State private var pitchBendRange = 12
    @State private var vibratoCC = 1
    @State private var expressionCC = 11
    @State private var trackpadSustainEnabled = false
    @State private var trackpadSustainThreshold = 0.55
    @State private var magicMouseSustainEnabled = false
    @State private var magicMouseSustainGesture: MagicMouseSustainGesture = .touchHold

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "MIDI Helper",
                    subtitle: "Hold notes or chords on a keyboard/Logic instrument and add vibrato, pitch bend and expression with the trackpad, Magic Mouse, or both."
                )

                HStack(spacing: 14) {
                    Picker("Surface", selection: $surfaceSelection) {
                        ForEach(TouchSurfaceSelection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)

                    Picker("Helper Mode", selection: $mode) {
                        ForEach(MIDIHelperMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 420)

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

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HelperSurfaceMap(
                            states: studio.midiHelperStates,
                            mode: mode,
                            surfaceSelection: surfaceSelection,
                            active: studio.midiHelperRunning
                        )
                        .frame(minHeight: 390)

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
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
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

                        GroupBox("Sustain Pedal / MIDI CC64") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Trackpad Contact Sustain", isOn: $trackpadSustainEnabled)
                                    .disabled(!surfaceSelection.accepts(.trackpad))

                                if trackpadSustainEnabled {
                                    HStack {
                                        Text("Contact threshold")
                                            .font(.caption)
                                        Slider(value: $trackpadSustainThreshold, in: 0.05...1.0, step: 0.05)
                                        Text("\(Int(trackpadSustainThreshold * 100))%")
                                            .font(.caption.monospaced())
                                            .frame(width: 42)
                                    }
                                    .disabled(!surfaceSelection.accepts(.trackpad))
                                }

                                Text("Trackpad sustain uses the available contact-size estimate, not calibrated Force Touch pressure. Releasing below the threshold sends CC64 OFF.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Divider()

                                Toggle("Magic Mouse Touch Sustain", isOn: $magicMouseSustainEnabled)
                                    .disabled(!surfaceSelection.accepts(.magicMouse))

                                if magicMouseSustainEnabled {
                                    Picker("Mouse Gesture", selection: $magicMouseSustainGesture) {
                                        ForEach(MagicMouseSustainGesture.allCases) {
                                            Text($0.rawValue).tag($0)
                                        }
                                    }
                                    .disabled(!surfaceSelection.accepts(.magicMouse))
                                }

                                Text(magicMouseSustainGesture == .touchHold
                                     ? "Touch Hold: sustain is active while one or more fingers touch the Magic Mouse."
                                     : "Tap Toggle: a new mouse touch session alternately enables and releases sustain.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Image(systemName: studio.midiHelperSustainActive
                                          ? "pedal.accelerator"
                                          : "circle.dashed")
                                    Text(studio.midiHelperSustainActive ? "CC64 ON · Sustain Active" : "CC64 OFF · Sustain Released")
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                }
                                .foregroundStyle(studio.midiHelperSustainActive ? Color.green : Color.secondary)

                                Text("Both surfaces combine into one CC64 state. Choose the same Target Channel as your Logic instrument. Stop/Panic always releases Helper sustain.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }

                        GroupBox("Gesture Mapping") {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Horizontal → Pitch Bend", systemImage: "arrow.left.and.right")
                                Label("Vertical → Vibrato / Modulation", systemImage: "arrow.up.and.down")
                                Label("Contact size → Expression", systemImage: "circle.dotted")
                                Divider()
                                Text("Hybrid combines all three. Multiple fingers are aggregated: average horizontal bend, strongest vertical vibrato, strongest contact expression.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }

                        GroupBox("Surface Notes") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Trackpad: full X/Y multi-touch plus contact-size pressure proxy.")
                                Text("Magic Mouse: X/Y multi-touch and contact-size proxy; it has no Force Touch haptic motor.")
                                Text("Both: gestures from both surfaces can contribute at the same time.")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                        }
                    }
                    .frame(width: 360)
                }

                Text("Preview is always visible on this page. Start MIDI Helper only enables MIDI control and optional local haptic playback.")
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
        .onChange(of: mode) { _ in syncIfRunning() }
        .onChange(of: sendToDAW) { _ in syncIfRunning() }
        .onChange(of: localSound) { _ in syncIfRunning() }
        .onChange(of: targetChannel) { _ in syncIfRunning() }
        .onChange(of: pitchBendRange) { _ in syncIfRunning() }
        .onChange(of: vibratoCC) { _ in syncIfRunning() }
        .onChange(of: expressionCC) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainEnabled) { _ in syncIfRunning() }
        .onChange(of: trackpadSustainThreshold) { _ in syncIfRunning() }
        .onChange(of: magicMouseSustainEnabled) { _ in syncIfRunning() }
        .onChange(of: magicMouseSustainGesture) { _ in syncIfRunning() }
    }

    private func startHelper() {
        studio.startMIDIHelper(
            mode: mode,
            surfaceSelection: surfaceSelection,
            sendToDAW: sendToDAW,
            localSound: localSound,
            targetChannel: targetChannel - 1,
            pitchBendRange: pitchBendRange,
            vibratoCC: vibratoCC,
            expressionCC: expressionCC,
            trackpadSustainEnabled: trackpadSustainEnabled,
            trackpadSustainThreshold: trackpadSustainThreshold,
            magicMouseSustainEnabled: magicMouseSustainEnabled,
            magicMouseSustainGesture: magicMouseSustainGesture
        )
    }

    private func syncIfRunning() {
        if studio.midiHelperRunning {
            startHelper()
        }
    }
}

private struct HelperSurfaceMap: View {
    let states: [TouchPerformanceState]
    let mode: MIDIHelperMode
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
                    Text(mode == .pitchBend ? "Pitch Bend" : "Vibrato")
                        .font(.headline)
                    Text(mode == .pitchBend ? "horizontal active" : "up = more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if mode == .expression || mode == .hybrid {
                        Text("Contact size = Expression")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)

                HStack {
                    if mode == .pitchBend || mode == .hybrid {
                        Label("Bend −", systemImage: "arrow.left")
                    }
                    Spacer()
                    if mode == .pitchBend || mode == .hybrid {
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
