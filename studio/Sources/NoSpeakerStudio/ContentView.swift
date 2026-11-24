#if os(macOS)
import SwiftUI
import Combine
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import NoSpeakerCore
import NoSpeakerMac

private struct VoiceDraft {
    var text: String = StudioController.startupGreeting
    var selectedLanguage: VoiceLanguage = .turkish
    var selectedVoice: String = ""
}

private struct TouchDraft: Codable {
    var root: Int = 67
    var scale: TouchScale = .pentatonic
    var fretless: Bool = false
    var zoneWidth: Double = 1.0
    var pitchSpan: Double = 24.0
    var surfaceSelection: TouchSurfaceSelection = .trackpad
    var triggerMode: TouchTriggerMode = .touch
    var pressThreshold: Double = 0.5
    var velocityFromPressure: Bool = false
    var fixedVelocity: Int = 100
    var pressureToExpression: Bool = true
    var localHapticSound: Bool = true
    var multiTouch: Bool = true
    var midiMode: TouchMIDIMode = .standard
    var midiChannel: Int = 1
    var trackpadInstrument: SurfaceInstrumentMode = .melodic
    var magicMouseInstrument: SurfaceInstrumentMode = .melodic
    var trackpadOutput: SurfaceOutputRoute = .trackpadHaptic
    var magicMouseOutput: SurfaceOutputRoute = .midiInstrument
    var drumLayout: DrumPadLayout = .standard12
    var stringLayout: StringSurfaceLayout? = nil
    var mouseStringLayout: StringSurfaceLayout? = nil
    var sustainEnabled: Bool = false
    var sustainTrackpadEnabled: Bool = true
    var sustainTrackpadGesture: TrackpadSustainGesture = .contactThreshold
    var sustainTrackpadThreshold: Double = 0.55
    var sustainTrackpadSensor: TrackpadSustainSensor = .contactSize
    var sustainMouseEnabled: Bool = false
    var sustainMouseGesture: MagicMouseSustainGesture = .touchHold
    var sustainMouseTapThreshold: Double? = nil
}

private struct HelperDraft: Codable {
    var surfaceSelection: TouchSurfaceSelection = .trackpad
    var sendToDAW: Bool = true
    var localSound: Bool = false
    var targetChannel: Int = 1
    var pitchBendRange: Int = 12
    var vibratoCC: Int = 1
    var expressionCC: Int = 11
    var vibratoEnabled: Bool = true
    var pitchBendEnabled: Bool = true
    var expressionEnabled: Bool = true
    var sustainEnabled: Bool = false
    var trackpadSustainEnabled: Bool = true
    var trackpadSustainThreshold: Double = 0.55
    var trackpadSustainSensor: TrackpadSustainSensor = .contactSize
    var trackpadSustainGesture: TrackpadSustainGesture = .contactThreshold
    var magicMouseSustainEnabled: Bool = false
    var magicMouseSustainGesture: MagicMouseSustainGesture = .touchHold
    var magicMouseTapThreshold: Double? = nil
}

private struct NoteDraft: Codable {
    var notes: [Int?] = Array(repeating: nil, count: 16)
    var selectedMIDI: Int = 72
    var velocity: Double = 0.85
    var loop: Bool = false
    var groove: GrooveSettings?
    var output: MusicalOutput?
}

private struct DrumDraft: Codable {
    var active: Set<String> = ["kick:0","kick:8","snare:4","snare:12","closedHat:0","closedHat:2","closedHat:4","closedHat:6","closedHat:8","closedHat:10","closedHat:12","closedHat:14"]
    var loop: Bool = false
    var groove: GrooveSettings?
    var output: MusicalOutput?
}

/// A saved workspace is declarative settings, not an executable instrument or a
/// running session. It deliberately excludes voice text, files, permissions,
/// remote addresses and capture shortcuts.
private struct WorkspaceSettings: Codable {
    var touch: TouchDraft
    var helper: HelperDraft
    var notes: NoteDraft
    var drums: DrumDraft
    var bpm: Double
    var orientation: SurfaceOrientation

    var isValid: Bool {
        (24...96).contains(touch.root) &&
        (0.5...2.0).contains(touch.zoneWidth) &&
        (1...96).contains(touch.pitchSpan) &&
        (0.1...1).contains(touch.pressThreshold) &&
        (1...127).contains(touch.fixedVelocity) &&
        (1...16).contains(touch.midiChannel) &&
        (touch.stringLayout?.isValid ?? true) &&
        (touch.mouseStringLayout?.isValid ?? true) &&
        (0.1...1).contains(touch.sustainTrackpadThreshold) &&
        (0...1).contains(touch.sustainMouseTapThreshold ?? 0) &&
        (1...16).contains(helper.targetChannel) &&
        [2, 5, 12, 24].contains(helper.pitchBendRange) &&
        (0...127).contains(helper.vibratoCC) &&
        (0...127).contains(helper.expressionCC) &&
        (0.1...1).contains(helper.trackpadSustainThreshold) &&
        (0...1).contains(helper.magicMouseTapThreshold ?? 0) &&
        notes.notes.count == 16 &&
        notes.notes.allSatisfy { $0.map { (0...127).contains($0) } ?? true } &&
        (48...95).contains(notes.selectedMIDI) &&
        (0.1...1).contains(notes.velocity) &&
        (notes.groove?.isValid ?? true) && (drums.groove?.isValid ?? true) &&
        drums.active.count <= 96 &&
        drums.active.isSubset(of: Self.validDrumSteps) &&
        (20...300).contains(bpm)
    }

    private static var validDrumSteps: Set<String> {
        Set(["kick", "snare", "closedHat", "openHat", "clap", "tom"].flatMap { voice in
            (0..<16).map { "\(voice):\($0)" }
        })
    }
}

private enum QuickWorkspace: String, CaseIterable, Identifiable {
    case solo = "Solo Haptic"
    case logic = "Logic Instrument"
    case hybrid = "Trackpad + Mouse Helper"
    case reverse = "Mouse + Trackpad Helper"
    case drums = "GM Drum Kit"

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .solo: "Trackpad melody, local haptic output."
        case .logic: "Trackpad melody routed to your DAW."
        case .hybrid: "Trackpad plays notes; Magic Mouse controls expression."
        case .reverse: "Magic Mouse plays notes; Trackpad controls expression."
        case .drums: "Trackpad GM percussion, 16 pads, local haptics."
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var mode: StudioMode? = .performance
    @State private var voiceDraft = VoiceDraft()
    @State private var touchDraft = TouchDraft()
    @State private var helperDraft = HelperDraft()
    @State private var noteDraft = NoteDraft()
    @State private var drumDraft = DrumDraft()
    @State private var tapTempo = TapTempo()
    @State private var compactTransport = false
    @State private var showChordStrip = false
    @State private var workspaceName = "Untitled Workspace"
    @State private var workspaceMessage = ""
    @State private var pendingWorkspace: QuickWorkspace?

    private var workspaceEditable: Bool {
        !studio.touchRunning && !studio.midiHelperRunning && !studio.midiRunning && !studio.sequenceRunning && !studio.patchRunning &&
        !studio.speakerBusy && !studio.chordArmed && !studio.touchBarOutputArmed && !studio.isPlaying && !studio.liveHingeEnabled &&
        !studio.captureArmed && !studio.pointerCaptured && !studio.touchBarSustainOn
    }

    private var navigationGroups: [(String, [StudioMode])] {
        [
            ("Workspace", [.performance, .mapping]),
            ("Play", [.chords, .touch, .midiHelper, .touchBar]),
            ("Compose", [.notes, .drums, .midi]),
            ("Sound", [.voice, .audio, .speaker]),
            ("Support", [.diagnostics, .about])
        ]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $mode) {
                ForEach(navigationGroups.indices, id: \.self) { index in
                    Section(navigationGroups[index].0) {
                        ForEach(navigationGroups[index].1) { item in
                            HStack {
                                Label(item.rawValue, systemImage: icon(for: item))
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if isSessionActive(item) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                        .accessibilityLabel("Session active")
                                }
                            }.tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 280)
            .navigationTitle("TIHULU Instrument")
            .safeAreaInset(edge: .bottom) { attribution }
        } detail: {
            VStack(spacing: 0) {
                transport
                Divider()
                if showChordStrip && mode != .chords && !(mode == .touchBar && studio.touchBarProfile.zones.contains(.chords)) {
                    ChordPadPanel(compact: true).padding(8)
                    Divider()
                }
                Group {
                    switch mode ?? .performance {
                    case .performance: PerformanceOverview(
                        open: { mode = $0 }, workspaceName: workspaceName,
                        workspaceMessage: workspaceMessage, workspaceEditable: workspaceEditable,
                        choose: { pendingWorkspace = $0 }, save: saveWorkspace, load: loadWorkspace
                    )
                    case .mapping: InstrumentBuilderView()
                    case .chords: ChordPadPanel(compact: false)
                    case .voice: VoiceModeView(text: $voiceDraft.text, selectedLanguage: $voiceDraft.selectedLanguage, selectedVoice: $voiceDraft.selectedVoice)
                    case .touch: TouchInstrumentView(root: $touchDraft.root, scale: $touchDraft.scale, fretless: $touchDraft.fretless, zoneWidth: $touchDraft.zoneWidth, pitchSpan: $touchDraft.pitchSpan, surfaceSelection: $touchDraft.surfaceSelection, triggerMode: $touchDraft.triggerMode, pressThreshold: $touchDraft.pressThreshold, velocityFromPressure: $touchDraft.velocityFromPressure, fixedVelocity: $touchDraft.fixedVelocity, pressureToExpression: $touchDraft.pressureToExpression, localHapticSound: $touchDraft.localHapticSound, multiTouch: $touchDraft.multiTouch, midiMode: $touchDraft.midiMode, midiChannel: $touchDraft.midiChannel, trackpadInstrument: $touchDraft.trackpadInstrument, magicMouseInstrument: $touchDraft.magicMouseInstrument, trackpadOutput: $touchDraft.trackpadOutput, magicMouseOutput: $touchDraft.magicMouseOutput, drumLayout: $touchDraft.drumLayout, stringLayout: $touchDraft.stringLayout, mouseStringLayout: $touchDraft.mouseStringLayout, sustainEnabled: $touchDraft.sustainEnabled, sustainTrackpadEnabled: $touchDraft.sustainTrackpadEnabled, sustainTrackpadGesture: $touchDraft.sustainTrackpadGesture, sustainTrackpadThreshold: $touchDraft.sustainTrackpadThreshold, sustainTrackpadSensor: $touchDraft.sustainTrackpadSensor, sustainMouseEnabled: $touchDraft.sustainMouseEnabled, sustainMouseGesture: $touchDraft.sustainMouseGesture, sustainMouseTapThreshold: $touchDraft.sustainMouseTapThreshold)
                    case .midiHelper: MIDIHelperView(surfaceSelection: $helperDraft.surfaceSelection, sendToDAW: $helperDraft.sendToDAW, localSound: $helperDraft.localSound, targetChannel: $helperDraft.targetChannel, pitchBendRange: $helperDraft.pitchBendRange, vibratoCC: $helperDraft.vibratoCC, expressionCC: $helperDraft.expressionCC, vibratoEnabled: $helperDraft.vibratoEnabled, pitchBendEnabled: $helperDraft.pitchBendEnabled, expressionEnabled: $helperDraft.expressionEnabled, sustainEnabled: $helperDraft.sustainEnabled, trackpadSustainEnabled: $helperDraft.trackpadSustainEnabled, trackpadSustainThreshold: $helperDraft.trackpadSustainThreshold, trackpadSustainSensor: $helperDraft.trackpadSustainSensor, trackpadSustainGesture: $helperDraft.trackpadSustainGesture, magicMouseSustainEnabled: $helperDraft.magicMouseSustainEnabled, magicMouseSustainGesture: $helperDraft.magicMouseSustainGesture, magicMouseTapThreshold: $helperDraft.magicMouseTapThreshold)
                    case .touchBar: TouchBarModeView()
                    case .notes: NoteSequencerView(notes: $noteDraft.notes, selectedMIDI: $noteDraft.selectedMIDI, velocity: $noteDraft.velocity, loop: $noteDraft.loop, groove: $noteDraft.groove, output: $noteDraft.output)
                    case .drums: DrumSequencerView(active: $drumDraft.active, loop: $drumDraft.loop, groove: $drumDraft.groove, output: $drumDraft.output)
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
        .confirmationDialog("Replace instrument and helper settings?", isPresented: Binding(
            get: { pendingWorkspace != nil },
            set: { if !$0 { pendingWorkspace = nil } }
        ), titleVisibility: .visible, presenting: pendingWorkspace) { template in
            Button("Prepare " + template.rawValue) {
                prepareWorkspace(template)
                pendingWorkspace = nil
            }
            Button("Cancel", role: .cancel) { pendingWorkspace = nil }
        } message: { _ in
            Text("This changes the instrument and helper drafts, not your sequencer patterns. It will not start a session.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            studio.attachNativeTouchBarToWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            studio.releaseChordPads()
            studio.releaseOptionalTouchBarNotes()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            studio.stopInstrumentPatch()
            studio.stopLiveSequence()
            studio.disarmChordPads()
            studio.disarmTouchBarOutput()
        }
        .onDisappear {
            studio.stopInstrumentPatch()
            studio.stopLiveSequence()
            studio.disarmChordPads()
            studio.disarmTouchBarOutput()
        }
        .onAppear {
            studio.installTouchBar()
            studio.playStartupGreetingOnce()
        }
    }

    private func prepareWorkspace(_ template: QuickWorkspace) {
        guard workspaceEditable else { return }
        var instrument = TouchDraft()
        var helper = HelperDraft()
        switch template {
        case .solo: break
        case .logic:
            instrument.trackpadOutput = .midiInstrument
        case .hybrid:
            instrument.trackpadOutput = .midiInstrument
            helper.surfaceSelection = .magicMouse
        case .reverse:
            instrument.surfaceSelection = .magicMouse
            instrument.magicMouseOutput = .midiInstrument
            helper.surfaceSelection = .trackpad
        case .drums:
            instrument.trackpadInstrument = .drums
            instrument.drumLayout = .grid16
        }
        touchDraft = instrument
        helperDraft = helper
        workspaceName = template.rawValue
        workspaceMessage = "Prepared. Open Touch Instrument and press Start when ready. Start MIDI Helper separately if needed."
        mode = .touch
    }

    private func saveWorkspace() {
        guard workspaceEditable else { return }
        let settings = WorkspaceSettings(touch: touchDraft, helper: helperDraft,
            notes: noteDraft, drums: drumDraft, bpm: TapTempo.safeBPM(studio.bpm),
            orientation: studio.magicMouseOrientation)
        guard settings.isValid else {
            workspaceMessage = "Invalid settings. Check the instrument and pattern values."
            return
        }
        do {
            let data = try WorkspaceArchive.encode(name: workspaceName, payload: settings)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "TIHULU Workspace.json"
            guard panel.runModal() == .OK, let url = panel.url, workspaceEditable else { return }
            try data.write(to: url, options: .atomic)
            workspaceMessage = "Workspace saved. Voice text, permissions and running sessions were not exported."
        } catch {
            workspaceMessage = "Unable to save workspace: " + error.localizedDescription
        }
    }

    private func loadWorkspace() {
        guard workspaceEditable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, workspaceEditable else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: WorkspaceArchive.maximumBytes + 1) ?? Data()
            let archive = try WorkspaceArchive.decode(WorkspaceSettings.self, from: data)
            guard archive.payload.isValid else { throw WorkspaceArchiveError.invalidPayload }
            let prompt = NSAlert()
            prompt.messageText = "Replace the current workspace?"
            prompt.informativeText = "This replaces instrument, helper and sequencer drafts. It does not start playback or enable capture."
            prompt.addButton(withTitle: "Load")
            prompt.addButton(withTitle: "Cancel")
            guard prompt.runModal() == .alertFirstButtonReturn, workspaceEditable else { return }
            let settings = archive.payload
            touchDraft = settings.touch
            helperDraft = settings.helper
            noteDraft = settings.notes
            drumDraft = settings.drums
            studio.bpm = settings.bpm
            studio.setMagicMouseOrientation(settings.orientation)
            workspaceName = archive.name
            workspaceMessage = "Workspace loaded. Start each instrument explicitly when ready."
        } catch {
            workspaceMessage = "Unable to load workspace: " + error.localizedDescription
        }
    }

    private func isSessionActive(_ item: StudioMode) -> Bool {
        switch item {
        case .chords: studio.chordArmed
        case .touch: studio.touchRunning
        case .midiHelper: studio.midiHelperRunning
        case .midi: studio.midiRunning
        case .speaker: studio.systemAudioRunning
        case .touchBar: studio.liveHingeEnabled || studio.touchBarSustainOn || studio.touchBarOutputArmed
        default: false
        }
    }

    private var transport: some View {
        VStack(spacing: 6) {
          HStack(spacing: 12) {
            Button {
                mode = .performance
            } label: {
                Label("Performance", systemImage: "music.note.house")
            }
            .help("Return to the live session overview")
            Text("BPM")
            TextField("BPM", value: $studio.bpm, format: .number.precision(.fractionLength(0)))
                .frame(width: 58).textFieldStyle(.roundedBorder)
                .onSubmit { studio.bpm = TapTempo.safeBPM(studio.bpm) }
            Button("Tap") {
                if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) {
                    studio.bpm = bpm
                }
            }.help("Tap repeatedly to set the pattern tempo")
            Spacer(minLength: 4)
            if studio.patchRunning {
                Button("Stop Builder") { studio.stopInstrumentPatch() }
                    .help("Release only the Instrument Builder session")
            }
            Button("Stop Playback") { studio.stopPlayback() }.keyboardShortcut(".", modifiers: .command)
                .help("Stop file, voice or sequencer playback; independent live sessions remain active")
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
            Slider(value: $studio.masterLevel, in: 0...1) { Text("Master") }.frame(width: 110)
                .help("Haptic level; restart playback or a capture session if its level is not updated live")
            Text("\(Int(studio.masterLevel * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
          }
          HStack(spacing: 8) {
              Circle().fill(studio.engineReady ? Color.green : Color.orange).frame(width: 8, height: 8)
              Text(studio.engineStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              if !studio.engineReady { Button("Reconnect") { studio.reconnect() } }
              Spacer()
              Label(studio.pointerCaptured ? "Pointer Captured" : "Pointer Free",
                    systemImage: studio.pointerCaptured ? "lock.fill" : "lock.open")
                  .font(.caption.weight(.semibold))
              Button { showChordStrip.toggle() } label: {
                  Label(showChordStrip ? "Hide Chord Pads" : "Chord Pads", systemImage: "pianokeys")
              }.help("Open shared chord pads alongside any performance mode")
              Button { compactTransport.toggle() } label: {
                  Label("Capture Settings", systemImage: compactTransport ? "chevron.down" : "chevron.up")
                      .labelStyle(.iconOnly)
              }.help("Show or hide capture and mouse orientation controls")
          }
          if !compactTransport {
          HStack(spacing: 12) {
              Toggle("Global Capture", isOn: Binding(
                  get: { studio.captureArmed },
                  set: { studio.configurePerformanceCapture(armed: $0, shortcut: studio.captureShortcut) }
              )).toggleStyle(.switch)
              PerformanceShortcutRecorder()
              Button(studio.pointerCaptured ? "Release" : "Capture Now") { studio.togglePointerCaptureNow() }
                  .disabled(!studio.captureArmed && !studio.pointerCaptured)
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
              Text("Esc = Kill Switch").foregroundStyle(.red).font(.caption.bold())
          }
          }
          if studio.touchRunning || studio.midiHelperRunning || studio.systemAudioRunning {
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
                  if studio.systemAudioRunning {
                      Button("Stop System Audio") { studio.stopSystemAudio() }
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
        case .performance: "music.note.house"
        case .mapping: "point.3.connected.trianglepath.dotted"
        case .chords: "pianokeys"
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

private struct PerformanceOverview: View {
    @EnvironmentObject private var studio: StudioController
    let open: (StudioMode) -> Void
    let workspaceName: String
    let workspaceMessage: String
    let workspaceEditable: Bool
    let choose: (QuickWorkspace) -> Void
    let save: () -> Void
    let load: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Performance", subtitle: "Choose an instrument, keep other sessions running, and stop each source independently.")
                GroupBox("Live sessions") {
                    VStack(spacing: 0) {
                        session("Chord Pads", detail: studio.chordBank.effectiveOutput.rawValue + " · shared chord bank", symbol: "pianokeys",
                                active: studio.chordArmed, page: .chords, stop: { studio.disarmChordPads() })
                        Divider()
                        session("Touch Instrument", detail: studio.touchSessionSummary, symbol: "hand.point.up.left",
                                active: studio.touchRunning, page: .touch, stop: { studio.stopTouch() })
                        Divider()
                        session("MIDI Helper", detail: studio.helperSessionSummary, symbol: "slider.horizontal.3",
                                active: studio.midiHelperRunning, page: .midiHelper, stop: { studio.stopMIDIHelper() })
                        Divider()
                        session("MIDI / Logic", detail: "Virtual MIDI bridge", symbol: "cable.connector",
                                active: studio.midiRunning, page: .midi, stop: nil)
                        Divider()
                        session("Trackpad Speaker", detail: "Live system audio", symbol: "speaker.wave.2",
                                active: studio.systemAudioRunning, page: .speaker, stop: { studio.stopSystemAudio() })
                        Divider()
                        session("Touch Bar Output", detail: studio.touchBarOutputStatus, symbol: "pianokeys",
                                active: studio.touchBarOutputArmed, page: .touchBar, stop: { studio.disarmTouchBarOutput() })
                        Divider()
                        session("Lid Sensor", detail: studio.hingeSensorStatus, symbol: "laptopcomputer",
                                active: studio.liveHingeEnabled, page: .touchBar, stop: { studio.enableLiveHinge(false) })
                    }.padding(6)
                }
                GroupBox("Workspace & quick setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(workspaceName).font(.headline)
                            Spacer()
                            Button("Save Workspace", action: save)
                            Button("Load Workspace", action: load)
                        }
                        .disabled(!workspaceEditable)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                            ForEach(QuickWorkspace.allCases) { template in
                                Button { choose(template) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.rawValue).font(.headline)
                                        Text(template.detail).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .padding(8)
                                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.disabled(!workspaceEditable)
                        if !workspaceEditable {
                            Text("Stop live sessions and playback, disable the MIDI bridge, hinge and Global Capture before replacing a workspace.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !workspaceMessage.isEmpty {
                            Text(workspaceMessage).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }.padding(6)
                }
                Text("Play & compose").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    launch("Chord Pads", "Scale-based chords and custom voicings", "pianokeys", .chords)
                    launch("Touch Instrument", "Melody, fretless and GM drums", "hand.point.up.left", .touch)
                    launch("MIDI Helper", "Bend, vibrato, expression and sustain", "slider.horizontal.3", .midiHelper)
                    launch("Touch Bar & Tilt", "Custom controls and lid mapping", "pianokeys", .touchBar)
                    launch("Note Sequencer", "Build a melodic pattern", "music.note.list", .notes)
                    launch("Drum Sequencer", "Build a rhythmic pattern", "circle.grid.cross", .drums)
                    launch("Voice", "Render speech on the trackpad", "text.bubble", .voice)
                    launch("Instrument Builder", "Create and test custom sensor-to-MIDI mappings", "point.3.connected.trianglepath.dotted", .mapping)
                }
                Text("Instrument Builder supports saved mappings, simulated and experimental native surface input with optional dedicated MIDI output. Camera and Remote are planned.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func session(_ name: String, detail: String, symbol: String, active: Bool,
                         page: StudioMode, stop: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 25).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Label(active ? "Active" : "Idle", systemImage: active ? "circle.fill" : "circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? Color.green : Color.secondary)
            Button("Open") { open(page) }
            if active, let stop {
                Button("Stop", action: stop).tint(.red)
                    .accessibilityLabel("Stop " + name)
            }
        }.padding(.vertical, 9)
    }

    private func launch(_ name: String, _ detail: String, _ symbol: String, _ page: StudioMode) -> some View {
        Button { open(page) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
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
    @Binding var text: String
    @Binding var selectedLanguage: VoiceLanguage
    @Binding var selectedVoice: String
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

                    Button("Stop") { studio.stopRenderedPlayback() }
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
                            Text("Add a local Piper model (.onnx and matching .onnx.json) to the app's Voice folder. Female and male voice models can coexist with Tihulu (the installed macOS Yelda voice). Models are not downloaded or redistributed automatically; check each model's license.")
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
            selectedVoice = (selectedLanguage == .turkish
                ? voices.first(where: { $0.id == "say:Yelda" })?.id
                : nil) ?? voices.first?.id ?? ""
        }
    }
}

private struct TouchInstrumentView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var showAdvanced = false

    @Binding var root: Int
    @Binding var scale: TouchScale
    @Binding var fretless: Bool
    @Binding var zoneWidth: Double
    @Binding var pitchSpan: Double
    @Binding var surfaceSelection: TouchSurfaceSelection
    @Binding var triggerMode: TouchTriggerMode
    @Binding var pressThreshold: Double
    @Binding var velocityFromPressure: Bool
    @Binding var fixedVelocity: Int
    @Binding var pressureToExpression: Bool
    @Binding var localHapticSound: Bool
    @Binding var multiTouch: Bool
    @Binding var midiMode: TouchMIDIMode
    @Binding var midiChannel: Int

    @Binding var trackpadInstrument: SurfaceInstrumentMode
    @Binding var magicMouseInstrument: SurfaceInstrumentMode
    @Binding var trackpadOutput: SurfaceOutputRoute
    @Binding var magicMouseOutput: SurfaceOutputRoute
    @Binding var drumLayout: DrumPadLayout
    @Binding var stringLayout: StringSurfaceLayout?
    @Binding var mouseStringLayout: StringSurfaceLayout?
    @Binding var sustainEnabled: Bool
    @Binding var sustainTrackpadEnabled: Bool
    @Binding var sustainTrackpadGesture: TrackpadSustainGesture
    @Binding var sustainTrackpadThreshold: Double
    @Binding var sustainTrackpadSensor: TrackpadSustainSensor
    @Binding var sustainMouseEnabled: Bool
    @Binding var sustainMouseGesture: MagicMouseSustainGesture
    @Binding var sustainMouseTapThreshold: Double?

    private var effectivePitchSpan: Double { 24.0 / zoneWidth }

    private var mappedMIDINotes: [Int] { configuration.mappedMIDINotes }

    private var hasMelodic: Bool {
        (surfaceSelection.accepts(.trackpad) && trackpadInstrument == .melodic) ||
        (surfaceSelection.accepts(.magicMouse) && magicMouseInstrument == .melodic)
    }

    private var hasGuitar: Bool {
        (surfaceSelection.accepts(.trackpad) && trackpadInstrument.isStringSurface) ||
        (surfaceSelection.accepts(.magicMouse) && magicMouseInstrument.isStringSurface)
    }
    private var effectiveStringLayout: StringSurfaceLayout { stringLayout ?? .init() }

    private var hasChords: Bool {
        (surfaceSelection.accepts(.trackpad) && trackpadInstrument == .chords) ||
        (surfaceSelection.accepts(.magicMouse) && magicMouseInstrument == .chords)
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
            drumLayout: drumLayout,
            customScale: studio.touchCustomScale,
            physicalChordBank: hasChords ? studio.chordBank : nil,
            stringLayout: effectiveStringLayout,
            mouseStringLayout: mouseStringLayout
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Touch Instrument",
                    subtitle: "Play physical chord pads, GM drums or melodic notes with the trackpad and Magic Mouse. Route each surface to trackpad haptics, a DAW MIDI instrument, or both."
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
                                    trackpadSensor: sustainTrackpadSensor,
                                    magicMouseTapThreshold: sustainMouseTapThreshold ?? 0
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
                            Text(trackpadInstrument == .drums ? "GM · MIDI Ch 10" : (trackpadInstrument == .chords ? "Chord Bank · 8 pads" : trackpadInstrument.rawValue))
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
                            Text(magicMouseInstrument == .drums ? "GM · MIDI Ch 10" : (magicMouseInstrument == .chords ? "Chord Bank · 8 pads" : magicMouseInstrument.rawValue))
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
                        .disabled(studio.touchRunning || (!fretless && studio.touchCustomScale != nil))

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

                if hasMelodic {
                    GroupBox("Shared scale & tuning") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Use chord-bank scale") { studio.useChordBankScaleForTouch() }
                                if let custom = studio.touchCustomScale {
                                    Text(custom.name).font(.headline)
                                    Button("Use built-in Touch scale") { studio.clearTouchCustomScale() }
                                }
                            }.disabled(studio.touchRunning || fretless)
                            if fretless {
                                Text("Fretless uses continuous pitch; custom fret tuning is bypassed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let custom = studio.touchCustomScale {
                                Text("Copied from the chord bank; follows the Touch root and note width. Re-copy after editing the bank. " +
                                     (custom.isMicrotonal ? "Haptic notes use cent offsets. MIDI uses nominal notes only if approximation was allowed." : "Equal-tempered custom degrees."))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Optional: reuse any built-in or custom chord-bank scale for fretted notes.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !configuration.permitsMelodicMIDI {
                                Text("Choose a haptic melodic route or allow equal-tempered MIDI in the bank's Scale Editor, then re-copy.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }.padding(6)
                    }
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

                DisclosureGroup("Advanced controls: trigger, velocity, MIDI routing and sustain", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
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

                if hasGuitar {
                    if surfaceSelection.accepts(.trackpad) && trackpadInstrument.isStringSurface {
                        GroupBox("Trackpad · Strings") {
                            StringLayoutEditor(layout:Binding(
                                get:{ effectiveStringLayout },
                                set:{ stringLayout = $0 }
                            ))
                        }.disabled(studio.touchRunning)
                    }
                    if surfaceSelection.accepts(.magicMouse) && magicMouseInstrument.isStringSurface {
                        GroupBox("Magic Mouse · Strings") {
                            VStack(alignment:.leading,spacing:8) {
                                Toggle("Independent mouse tuning and span",isOn:Binding(
                                    get:{ mouseStringLayout != nil },
                                    set:{ mouseStringLayout = $0 ? effectiveStringLayout : nil }
                                ))
                                StringLayoutEditor(layout:Binding(
                                    get:{ mouseStringLayout ?? effectiveStringLayout },
                                    set:{ mouseStringLayout = $0 }
                                )).disabled(mouseStringLayout == nil)
                                if mouseStringLayout == nil {
                                    Text("Using the shared/Trackpad string layout. Enable independent tuning to edit the mouse separately.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(6)
                        }.disabled(studio.touchRunning)
                    }
                }
                if hasChords {
                    GroupBox("Physical Chord Pads") {
                        Text("Eight held-contact pads from the Chord Pads page. Edit the bank while Touch Instrument is stopped. Physical pads use the Touch output and velocity, not the bank’s timed gate or latch. MIDI requires Standard mode; microtonal MIDI needs explicit approximation.")
                            .font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
                if configuration.hasMIDIOutput {
                    GroupBox("Logic Pro / DAW MIDI Out") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                if hasMelodic || hasChords || hasGuitar {
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
                                magicMouseGesture: $sustainMouseGesture,
                                magicMouseTapThreshold: $sustainMouseTapThreshold,
                                mouseContactSize: studio.touchStates.filter { $0.surface == .magicMouse && $0.isTouching }.map(\.pressure).max()
                            )
                            .disabled(studio.touchRunning)
                        }
                    }
                    .padding(6)
                }

                CaptureSettingsPanel()
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
        .onChange(of: studio.touchCustomScale) { _ in syncConfiguration() }
        .onChange(of: studio.chordBank) { _ in if hasChords && !studio.touchRunning { syncConfiguration() } }
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
        .onChange(of: stringLayout) { _ in syncConfiguration() }
        .onChange(of: mouseStringLayout) { _ in syncConfiguration() }
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
                Text(instrument == .drums ? "GM Drum Pads" : (instrument == .chords ? "Physical Chord Pads" : instrument.rawValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Output: \(route.rawValue)")
                    .font(.caption.weight(.semibold))
            }

            TouchSurfaceMap(
                notes: mappedMIDINotes,
                drumLayout: drumLayout,
                chordBank: studio.chordBank,
                stringLayout: configuration.strings(for:surface),
                instrument: instrument,
                rootMIDI: root,
                fretless: fretless,
                pitchSpan: effectivePitchSpan,
                states: studio.touchStates.filter { $0.surface == surface },
                active: studio.touchRunning,
                surfaceSelection: surface == .trackpad ? .trackpad : .magicMouse
            )
            .frame(height: surfaceSelection == .both ? 240 : 340)
            if instrument == .drums {
                Text(drumLayout.isGrid
                     ? "Physical X/Y pads · lift and touch to strike another pad."
                     : "Legacy horizontal strip · lift and touch to retrigger haptics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func syncConfiguration() {
        studio.updateTouchConfiguration(configuration)
    }
}

private struct StringLayoutEditor: View {
    @Binding var layout: StringSurfaceLayout
    @State private var fretText = ""
    @State private var fretError = ""
    var body: some View {
                        VStack(alignment:.leading,spacing:8) {
                            Picker("Tuning",selection:Binding(
                                get:{ layout.tuning },
                                set:{ var next = layout; next.tuning = $0; next.customOpenNotes = nil; layout = next }
                            )) {
                                ForEach(StringTuning.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Stepper("Pitch span: \(layout.frets) semitones",value:Binding(
                                get:{ layout.frets },
                                set:{ var next = layout; next.frets = $0; if next.isValid { layout = next } }
                            ),in:4...24)
                            Picker("Fret division",selection:Binding(
                                get:{ layout.effectiveDivision },
                                set:{ var next = layout; next.fretDivision = $0 == .edo12 ? nil : $0; next.customFretCents = nil; layout = next; fretError = "" }
                            )) {
                                ForEach(StringFretDivision.allCases) { Text($0.title).tag($0) }
                            }
                            HStack {
                                TextField("Custom fret cents, e.g. 0, 200, 350, 500, 700, 1200",text:$fretText)
                                Button("Apply") {
                                    guard let cents = StringSurfaceLayout.parseFretCents(fretText) else {
                                        fretError = "Enter 2–107 increasing integer cent values, starting at 0."
                                        return
                                    }
                                    var next = layout
                                    next.customFretCents = cents
                                    guard next.isValid else {
                                        fretError = "Custom frets must fit inside the selected pitch span."
                                        return
                                    }
                                    layout = next
                                    fretError = ""
                                }
                                Button("Reset to EDO") {
                                    var next = layout
                                    next.customFretCents = nil
                                    layout = next
                                    fretError = ""
                                }.disabled(layout.customFretCents == nil)
                            }
                            if let cents = layout.customFretCents {
                                Text("Custom frets: " + cents.map(String.init).joined(separator:", "))
                                    .font(.caption).textSelection(.enabled)
                            }
                            if !fretError.isEmpty { Text(fretError).font(.caption).foregroundStyle(.orange) }
                            Text("\(layout.columns) discrete positions including open string. 24-EDO gives quarter tones; 53-EDO gives equal commas, not a complete makam. Custom fret cents override the EDO choice. Microtonal MIDI requires MPE. Fretless mode ignores fret divisions.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Custom open-string tuning",isOn:Binding(
                                get:{ layout.customOpenNotes != nil },
                                set:{ enabled in
                                    var next = layout
                                    next.customOpenNotes = enabled ? next.tuning.openNotes : nil
                                    layout = next
                                }
                            ))
                            if let notes = layout.customOpenNotes {
                                Stepper("Strings: \(notes.count)",value:Binding(
                                    get:{ notes.count },
                                    set:{ count in
                                        guard (3...8).contains(count) else { return }
                                        var next = layout
                                        var pitches = Array(notes.prefix(count))
                                        while pitches.count < count { pitches.append(max(0,(pitches.last ?? 40)-5)) }
                                        next.customOpenNotes = pitches
                                        if next.isValid { layout = next }
                                    }
                                ),in:3...8)
                                ForEach(notes.indices,id:\.self) { row in
                                    Stepper("String \(row+1): \((try? MusicTheory.noteName(midi:notes[row])) ?? String(notes[row])) · MIDI \(notes[row])",
                                        value:Binding(
                                            get:{ notes[row] },
                                            set:{ pitch in
                                                var next = layout
                                                guard var pitches = next.customOpenNotes, pitches.indices.contains(row) else { return }
                                                pitches[row] = pitch
                                                next.customOpenNotes = pitches
                                                if next.isValid { layout = next }
                                            }
                                        ),in:0...(127-layout.frets))
                                }
                            }
                            Text("X selects pitch, Y selects string. Fretted mode steps between notes; fretless mode slides continuously over the same semitone span and requires MPE for MIDI. Strum gestures are a follow-up. The haptic motor has a narrower frequency range than MIDI.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
    }
}

private struct TouchSurfaceMap: View {
    let notes: [Int]
    let drumLayout: DrumPadLayout
    private var drumPads: [DrumPad] { drumLayout.pads }
    let chordBank: ChordBank
    let stringLayout: StringSurfaceLayout
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

                if instrument == .guitar && stringLayout.isValid && stringLayout.isMicrotonal {
                    // Dense microtonal layout: one grid path, not hundreds
                    // of individual labels and repeated contact scans.
                    let w = proxy.size.width / CGFloat(stringLayout.columns)
                    let h = proxy.size.height / CGFloat(stringLayout.rows)
                    Path { path in
                        for i in 0...stringLayout.columns {
                            let x = CGFloat(i)*w
                            path.move(to:CGPoint(x:x,y:0))
                            path.addLine(to:CGPoint(x:x,y:proxy.size.height))
                        }
                        for i in 0..<stringLayout.rows {
                            let y = (CGFloat(i)+0.5)*h
                            path.move(to:CGPoint(x:0,y:y))
                            path.addLine(to:CGPoint(x:proxy.size.width,y:y))
                        }
                    }.stroke(Color.secondary.opacity(0.32),lineWidth:0.6)
                    ForEach(states.filter(\.isDown)) { state in
                        if let cell = stringLayout.cell(x:state.x,y:state.y) {
                            Rectangle().fill(Color.accentColor.opacity(0.45))
                                .frame(width:max(1,w),height:h)
                                .position(x:(CGFloat(cell.fret)+0.5)*w,y:(CGFloat(cell.string)+0.5)*h)
                        }
                    }
                } else if instrument == .fretlessStrings && stringLayout.isValid {
                    let height = proxy.size.height / CGFloat(stringLayout.rows)
                    ForEach(0..<stringLayout.rows,id:\.self) { row in
                        let openNote = stringLayout.openNotes[row]
                        ZStack(alignment:.leading) {
                            Rectangle().fill(states.contains { $0.isDown && stringLayout.continuousCell(x:$0.x,y:$0.y)?.string == row }
                                ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.04))
                            Rectangle().fill(Color.secondary.opacity(0.6)).frame(height:1)
                            Text((try? MusicTheory.noteName(midi:openNote)) ?? String(openNote))
                                .font(.caption2).padding(4).background(.background)
                        }.frame(width:proxy.size.width,height:height)
                        .position(x:proxy.size.width/2,y:(CGFloat(row)+0.5)*height)
                    }
                } else if instrument == .guitar && stringLayout.isValid {
                    let width = proxy.size.width / CGFloat(stringLayout.columns)
                    let height = proxy.size.height / CGFloat(stringLayout.rows)
                    ForEach(0..<stringLayout.rows,id:\.self) { row in
                        let openNote = stringLayout.openNotes[row]
                        ForEach(0..<stringLayout.columns,id:\.self) { fret in
                            let hit = states.contains {
                                $0.isDown && stringLayout.cell(x:$0.x,y:$0.y)?.string == row &&
                                (instrument == .fretlessStrings || stringLayout.cell(x:$0.x,y:$0.y)?.fret == fret)
                            }
                            ZStack {
                                Rectangle().fill(hit ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(fret == 0 ? 0.18 : 0.04))
                                Rectangle().strokeBorder(Color.secondary.opacity(instrument == .fretlessStrings ? 0.035 : 0.18))
                                Rectangle().fill(Color.secondary.opacity(0.6)).frame(height:1)
                                if fret == 0 {
                                    Text((try? MusicTheory.noteName(midi:openNote)) ?? String(openNote)).font(.caption2)
                                        .padding(2).background(.background)
                                } else if row == 0 {
                                    Text(String(fret)).font(.system(size:9,design:.monospaced))
                                        .padding(2).background(.background)
                                }
                            }.frame(width:width,height:height)
                            .position(x:(CGFloat(fret)+0.5)*width,y:(CGFloat(row)+0.5)*height)
                        }
                    }
                } else if instrument == .chords {
                    let width = proxy.size.width / 4
                    let height = proxy.size.height / 2
                    ForEach(0..<ChordBank.padCount,id:\.self) { slot in
                        let pad = chordBank.pad(at:slot)
                        let pressed = states.contains { $0.isDown && $0.chordSlot == slot }
                        ZStack {
                            RoundedRectangle(cornerRadius:8)
                                .fill(pressed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.08))
                            RoundedRectangle(cornerRadius:8).strokeBorder(Color.secondary.opacity(0.24))
                            VStack(spacing:4) {
                                Text(pad?.name ?? "Unavailable").font(.headline)
                                Text(pad?.noteNames ?? "").font(.caption2).lineLimit(2)
                            }.padding(3)
                        }
                        .frame(width:max(1,width-4),height:max(1,height-4))
                        .position(x:(CGFloat(slot % 4)+0.5)*width,y:(CGFloat(slot / 4)+0.5)*height)
                    }
                } else if instrument == .drums {
                    let cellWidth = proxy.size.width / CGFloat(drumLayout.columns)
                    let cellHeight = proxy.size.height / CGFloat(drumLayout.rows)
                    ForEach(drumPads.indices, id: \.self) { index in
                        let pad = drumPads[index]
                        let column = index % drumLayout.columns
                        let row = index / drumLayout.columns
                        let pressed = states.contains { $0.isDown && $0.quantizedMIDI == pad.midiNote }
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(pressed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.08))
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.24))
                            VStack(spacing: 4) {
                                Text(pad.name).font(.system(size: 12, weight: .semibold))
                                    .lineLimit(2).minimumScaleFactor(0.6)
                                Text("GM \(pad.midiNote)").font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(3)
                        }
                        .frame(width: max(1, cellWidth - 4), height: max(1, cellHeight - 4))
                        .position(x: (CGFloat(column) + 0.5) * cellWidth,
                                  y: (CGFloat(row) + 0.5) * cellHeight)
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

                if states.isEmpty && instrument == .melodic {
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

                if instrument == .melodic {
                    HStack {
                        Label("Lower pitch", systemImage: "arrow.left")
                        Spacer()
                        Text(fretless
                             ? "X = continuous pitch · Y = vibrato"
                             : "X = note zone · Y = vibrato")
                        Spacer()
                        Label("Higher pitch", systemImage: "arrow.right")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(width: proxy.size.width)
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 18)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(.secondary.opacity(0.24), lineWidth: 1))
        }
    }
}

private struct NoteSequencerView: View {
    @EnvironmentObject private var studio: StudioController
    @Binding var notes: [Int?]
    @Binding var selectedMIDI: Int
    @Binding var velocity: Double
    @Binding var loop: Bool
    @Binding var groove: GrooveSettings?
    @Binding var output: MusicalOutput?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Note Sequencer", subtitle: "Build or generate a 16-step melody and play it directly through the haptic motor.")
            NoteComposerPanel(notes: $notes)
            GroovePanel(settings: $groove)
            SequencerOutputPanel(output: $output)
            HStack {
                Stepper("Selected note: \((try? MusicTheory.noteName(midi: selectedMIDI)) ?? "-")", value: $selectedMIDI, in: 48...95)
                Slider(value: $velocity, in: 0.1...1) { Text("Velocity") }.frame(width: 180)
                Toggle("Loop", isOn: $loop).toggleStyle(.switch)
                Spacer()
                Button("Play Pattern") { play() }.buttonStyle(.borderedProminent).disabled(studio.sequenceRunning)
                MIDIClipExportButton(filename: "TIHULU Notes") {
                    try makeClip()
                }
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
    }

    private var noteSteps: [NoteStep] {
        notes.enumerated().compactMap { index, note -> NoteStep? in
            guard let note else { return nil }
            return NoteStep(index: index, midi: note, velocity: velocity, gate: 0.8)
        }
    }

    private func makeClip() throws -> MIDIClip {
        let clip = try MIDIClip.melody(.init(bpm: studio.bpm, steps: noteSteps))
        return try groove?.apply(to: clip) ?? clip
    }

    private func play() {
        if (output ?? .haptic).sendsMIDI { studio.startLiveSequence(output: output ?? .haptic, loop: loop, makeClip: makeClip) }
        else if groove != nil { studio.playGrooveClip(loop: loop, makeClip: makeClip) }
        else { studio.playNotes(noteSteps, loop: loop) }
    }
}

private struct DrumSequencerView: View {
    @EnvironmentObject private var studio: StudioController
    @Binding var active: Set<String>
    @Binding var loop: Bool
    @Binding var groove: GrooveSettings?
    @Binding var output: MusicalOutput?
    private let voices: [DrumVoice] = [.kick, .snare, .closedHat, .openHat, .clap, .tom]

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Drum Sequencer", subtitle: "Sequence or generate haptic kick, snare, hats, clap and tom voices.")
            DrumComposerPanel(active: $active)
            GroovePanel(settings: $groove)
            SequencerOutputPanel(output: $output)
            HStack {
                Toggle("Loop", isOn: $loop)
                Spacer()
                Button("Play Pattern") { play() }.buttonStyle(.borderedProminent).disabled(studio.sequenceRunning)
                MIDIClipExportButton(filename: "TIHULU Drums") {
                    try makeClip()
                }
                Button("Clear") { active.removeAll() }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Color.clear.frame(width: 86, height: 1)
                    ForEach(0..<4, id: \.self) { beat in
                        Text("Beat \(beat + 1)").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(voices, id: \.self) { voice in
                    HStack(spacing: 5) {
                        Text(label(voice)).font(.callout)
                            .frame(width: 86, alignment: .leading)
                        ForEach(0..<4, id: \.self) { beat in
                            HStack(spacing: 3) {
                                ForEach(0..<4, id: \.self) { subdivision in
                                    let step = beat * 4 + subdivision
                                    let key = "\(voice.rawValue):\(step)"
                                    let enabled = active.contains(key)
                                    Button {
                                        if enabled { active.remove(key) } else { active.insert(key) }
                                    } label: {
                                        Text("\(step + 1)").font(.caption.monospacedDigit())
                                            .frame(maxWidth: .infinity, minHeight: 29)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .tint(enabled ? .accentColor : .gray.opacity(beat.isMultiple(of: 2) ? 0.35 : 0.22))
                                    .accessibilityLabel("\(label(voice)), step \(step + 1)")
                                    .accessibilityValue(enabled ? "On" : "Off")
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }.padding(.vertical, 4)
            Spacer()
        }.padding(28)
        }
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
    private var drumHits: [DrumStep] {
        voices.flatMap { voice in (0..<16).compactMap { active.contains("\(voice.rawValue):\($0)") ? DrumStep(index: $0, voice: voice, velocity: 0.9) : nil } }
    }
    private func makeClip() throws -> MIDIClip {
        let clip = try MIDIClip.drums(.init(bpm: studio.bpm, hits: drumHits))
        return try groove?.apply(to: clip) ?? clip
    }

    private func play() {
        if (output ?? .haptic).sendsMIDI { studio.startLiveSequence(output: output ?? .haptic, loop: loop, makeClip: makeClip) }
        else if groove != nil { studio.playGrooveClip(loop: loop, makeClip: makeClip) }
        else { studio.playDrums(drumHits, loop: loop) }
    }
}


private struct MIDIHelperView: View {
    @EnvironmentObject private var studio: StudioController

    @Binding var surfaceSelection: TouchSurfaceSelection
    @Binding var sendToDAW: Bool
    @Binding var localSound: Bool
    @Binding var targetChannel: Int
    @Binding var pitchBendRange: Int
    @Binding var vibratoCC: Int
    @Binding var expressionCC: Int

    @Binding var vibratoEnabled: Bool
    @Binding var pitchBendEnabled: Bool
    @Binding var expressionEnabled: Bool
    @Binding var sustainEnabled: Bool

    @Binding var trackpadSustainEnabled: Bool
    @Binding var trackpadSustainThreshold: Double
    @Binding var trackpadSustainSensor: TrackpadSustainSensor
    @Binding var trackpadSustainGesture: TrackpadSustainGesture
    @Binding var magicMouseSustainEnabled: Bool
    @Binding var magicMouseSustainGesture: MagicMouseSustainGesture
    @Binding var magicMouseTapThreshold: Double?


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
                                if let target = studio.activeTouchControlChannel {
                                    Button("Use active Touch MIDI channel \(target + 1)") { targetChannel = target + 1 }
                                        .disabled(studio.midiHelperRunning)
                                } else if studio.touchRunning {
                                    Text("No standard melodic MIDI target. MPE, drums and haptic-only output require different routing.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Wah preset · Y → CC4") {
                                    vibratoEnabled = true
                                    vibratoCC = 4
                                    pitchBendEnabled = false
                                    expressionEnabled = false
                                    if let target = studio.activeTouchControlChannel { targetChannel = target + 1 }
                                }.disabled(studio.midiHelperRunning)
                                Text("CC4 requires DAW MIDI Learn. For shared fretted pitch bend disable conflicting controls; frets, fretless pitch and MPE ownership are not replaced by this preset.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Picker("Pitch Bend Range", selection: $pitchBendRange) {
                                    Text("±2 semitones").tag(2)
                                    Text("±5 semitones").tag(5)
                                    Text("±12 semitones").tag(12)
                                    Text("±24 semitones").tag(24)
                                }
                                Picker("Y / Vertical CC", selection: $vibratoCC) {
                                    if !HelperCCPolicy.permits(vibratoCC) {
                                        Text("CC \(vibratoCC) · Reserved").tag(vibratoCC)
                                    }
                                    ForEach(HelperCCPolicy.choices,id:\.self) { cc in Text("CC \(cc)").tag(cc) }
                                }
                                Picker("Expression CC", selection: $expressionCC) {
                                    if !HelperCCPolicy.permits(expressionCC) {
                                        Text("CC \(expressionCC) · Reserved").tag(expressionCC)
                                    }
                                    ForEach(HelperCCPolicy.choices,id:\.self) { cc in Text("CC \(cc)").tag(cc) }
                                }
                                if !HelperCCPolicy.permits(vibrato:vibratoEnabled,expression:expressionEnabled,
                                                           vibratoCC:vibratoCC,expressionCC:expressionCC) {
                                    Text("Choose distinct expressive CCs. Reserved controls cannot be sent from the Helper.")
                                        .font(.caption).foregroundStyle(.orange)
                                }
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
                                magicMouseGesture: $magicMouseSustainGesture,
                                magicMouseTapThreshold: $magicMouseTapThreshold,
                                mouseContactSize: studio.midiHelperStates.filter { $0.surface == .magicMouse && $0.isTouching }.map(\.pressure).max()
                            )
                        }

                        GroupBox("Gesture Mapping") {
                            VStack(alignment: .leading, spacing: 10) {
                                if pitchBendEnabled {
                                    Label("X / Horizontal → Pitch Bend", systemImage: "arrow.left.and.right")
                                }
                                if vibratoEnabled {
                                    Label("Y / Vertical → CC \(vibratoCC)" + (vibratoCC == 4 ? " · Wah" : ""), systemImage: "arrow.up.and.down")
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
            if studio.midiHelperRunning { syncIfRunning() }
            else { studio.updateMIDIHelperSurface(surfaceSelection) }
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
        .onChange(of: magicMouseTapThreshold) { _ in syncIfRunning() }
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
            trackpadSustainSensor: trackpadSustainSensor,
            magicMouseTapThreshold: magicMouseTapThreshold ?? 0
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
    @Binding var magicMouseTapThreshold: Double?
    let mouseContactSize: Double?

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
                    if magicMouseGesture == .tapToggle {
                        HStack {
                            Text("Tap contact threshold").font(.caption)
                            Slider(value: Binding(
                                get: { magicMouseTapThreshold ?? 0 },
                                set: { magicMouseTapThreshold = $0 }
                            ), in: 0...1, step: 0.05)
                            Text("\(Int((magicMouseTapThreshold ?? 0) * 100))%")
                                .font(.caption.monospacedDigit())
                        }
                        .disabled(playing || !surfaceSelection.accepts(.magicMouse))
                        if let size = mouseContactSize, size.isFinite, (0...1).contains(size) {
                            ProgressView(value: size) {
                                Text("Live contact size: \(Int(size * 100))%").font(.caption)
                            }
                        } else {
                            Text("Live contact size: no contact").font(.caption)
                        }
                        Text("0% accepts any new contact. Higher thresholds require a larger first contact; lifting is required before another toggle. Contact size is not pressure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
            if event.isARepeat { return nil }
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
                    Button(studio.pointerCaptured ? "Release" : "Capture Now") { studio.togglePointerCaptureNow() }
                        .disabled(!studio.captureArmed && !studio.pointerCaptured)
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
            HStack { Text(studio.currentFileName).foregroundStyle(.secondary); Spacer(); Button("Open Audio File…") { importing = true }; Button("Stop") { studio.stopRenderedPlayback() } }
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
            PageHeader(title: "Trackpad Speaker", subtitle: "Experimental speech-aware live audio. The Force Touch motor is not a conventional speaker.")
            Picker("Live profile", selection: $studio.speakerProfile) {
                Text("Speech Clarity").tag(AudioHapticProfile.voice)
                Text("Melody").tag(AudioHapticProfile.melody)
                Text("Rhythm").tag(AudioHapticProfile.rhythm)
                Text("Full Mix").tag(AudioHapticProfile.fullMix)
            }.pickerStyle(.segmented).disabled(studio.speakerBusy)
            GroupBox("Live audio processing") {
                VStack(alignment: .leading, spacing: 10) {
                    if studio.speakerProfile == .voice {
                        Toggle("Speech formants (off = legacy spectral comparison)", isOn: $studio.speakerOptimized)
                    }
                    Toggle("Automatic gain control", isOn: $studio.speakerAutomaticGain)
                    Toggle("Silence / low-level noise gate", isOn: $studio.speakerNoiseGate)
                    HStack {
                        Text("Playback buffer")
                        Slider(value: $studio.speakerBufferMS, in: 50...350, step: 25)
                        Text("\(Int(studio.speakerBufferMS)) ms").monospacedDigit().frame(width: 70)
                    }
                    Text("Changes apply on the next Start. Lower buffer reduces latency; higher buffer tolerates more capture jitter.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6).disabled(studio.speakerBusy)
            }
            GroupBox("Play a file as haptic audio") {
                HStack { Text(studio.currentFileName); Spacer(); Button("Choose Audio…") { importing = true } }.padding(6)
                    .disabled(studio.speakerBusy)
            }
            GroupBox("Live system audio") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture macOS system audio with ScreenCaptureKit and convert it to haptic output in real time.")
                    Text("macOS will request Screen Recording permission. This mode does not install a virtual audio driver and does not appear as a selectable physical output device in Sound Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(studio.systemAudioStopping ? "Stopping…" : (studio.speakerBusy ? "Stop System Audio" : "Start System Audio → Trackpad")) {
                            studio.speakerBusy ? studio.stopSystemAudio() : studio.startSystemAudio()
                        }.buttonStyle(.borderedProminent).disabled(studio.systemAudioStopping)
                        Text(studio.systemAudioStarting ? "Requesting capture…" : (studio.systemAudioRunning ? "Live · buffered" : "Idle"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
            Text("The trackpad actuator is not a hi-fi loudspeaker. Studio keeps the original project's normal motor level ceiling and prioritizes safety over loudness.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in if case .success(let url) = result { studio.playAudioFile(url) } }
    }
}

private struct TouchBarOutputSettings: View {
    @EnvironmentObject private var studio: StudioController
    var body: some View {
        GroupBox("Piano & fretless output") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Destination", selection: Binding(
                    get: { studio.touchBarProfile.effectiveOutput },
                    set: { output in
                        var profile = studio.touchBarProfile
                        profile.musicalOutput = output
                        studio.setTouchBarProfile(profile)
                    }
                )) {
                    ForEach(MusicalOutput.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(studio.touchBarOutputArmed)
                if studio.touchBarProfile.effectiveOutput.sendsHaptics {
                    HStack {
                        Button(studio.touchBarOutputArmed ? "Disarm" : "Arm Output") {
                            if studio.touchBarOutputArmed { studio.disarmTouchBarOutput() }
                            else { studio.armTouchBarOutput() }
                        }.buttonStyle(.borderedProminent)
                        Button("Release All") { studio.releaseOptionalTouchBarNotes() }
                        Text(studio.touchBarOutputStatus).font(.caption)
                    }
                    SharedNoteOutputSetting()
                    Text("Trackpad supports notes, fretless bend, expression and sustain. Vibrato/filter are MIDI controls in Both. Both uses the TIHULU Touch Bar source. Other legacy haptic engines require disarming first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Existing MIDI bridge behavior; no new haptic session is started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
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

                GroupBox("Native Touch Bar · Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Show / Reconnect Native Touch Bar") { studio.reconnectNativeTouchBar() }
                            .buttonStyle(.borderedProminent)
                        Text("AppKit item requests: \(studio.nativeTouchBarItemRequests) · Native control callbacks: \(studio.nativeTouchBarInputCount)")
                            .font(.caption.monospacedDigit())
                        Text("Bring this Studio window to the front. In macOS Keyboard settings choose App Controls where supported. Reconnect releases existing Touch Bar notes and controls; it does not arm output. Callback counts are not proof of physical hardware.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                TouchBarOutputSettings()
                GroupBox("Shared MIDI target") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let target = studio.activeTouchControlChannel {
                            Button("Use active Touch MIDI channel \(target + 1)") {
                                setProfile { profile in
                                    profile.channel = target
                                    profile.musicalOutput = .midi
                                }
                            }.disabled(studio.touchBarOutputArmed)
                        } else {
                            Text("Start a standard melodic Touch MIDI instrument to copy its actual channel.")
                        }
                        Text("Uses the existing shared MIDI source. Route it to the same DAW instrument. Wah CC4 requires MIDI Learn; haptic-only Wah and independent MPE bend mixing are not implemented. Channel is copied, not followed automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
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
                            case .chords:
                                ChordPadPanel(compact: true)
                            case .sustain:
                                HStack {
                                    Text("Sustain").frame(width: 115, alignment: .leading)
                                    if studio.touchBarProfile.sustainMode == .hold {
                                        TouchBarHoldSustainPad()
                                    } else {
                                        Button(studio.touchBarSustainOn ? "Sustain ON" : "Sustain OFF") {
                                            studio.touchBarSustainPressed(true)
                                        }
                                    }
                                }
                            case .fretless, .pitchBend, .vibrato, .expression, .filter, .wah:
                                TouchBarSliderPad(zone: zone)
                            }
                        }
                        Text("MIDI-only keeps the existing bridge. Optional Trackpad/Both uses the dedicated armed output. Chord Pads have their own output selector.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }

                GroupBox("Screen hinge as an instrument · Calibration simulator") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Map screen opening to wah (CC4), filter, expression, vibrato or pitch bend. Live hardware detection is experimental, manual-only and may be unsupported on Touch Bar MacBooks; use the simulator if no compatible sensor is available.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Enable Live Hinge Angle Sensor (Experimental)", isOn: Binding(
                            get: { studio.liveHingeEnabled },
                            set: { studio.enableLiveHinge($0) }
                        ))
                        Button("Probe Lid Sensor (Read Only)") { studio.probeLidSensor() }
                        Text(studio.hingeProbeStatus).font(.caption.monospacedDigit()).textSelection(.enabled)
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
                        Button("Stop Tilt & Return to Neutral") {
                            studio.returnTiltToNeutral()
                        }
                        .disabled(studio.touchBarProfile.tiltTarget == .disabled)
                    }.padding(8)
                }
                Text("Safety: Hinge sensor is explicitly opt-in and uses a read-only, undocumented HID report on compatible MacBooks. An unavailable sensor never starts monitoring. The app does not move the display, modify sleep settings, or send any telemetry.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}

private struct TouchBarHoldSustainPad: View {
    @EnvironmentObject private var studio: StudioController
    @State private var gesture: UInt64?
    var body: some View {
        Button(studio.touchBarSustainOn ? "HOLDING" : "Press & hold") {}
            .onLongPressGesture(minimumDuration: 0, pressing: { pressed in
                if pressed {
                    guard gesture == nil else { return }
                    gesture = studio.touchBarGestureEpoch.revision
                    studio.touchBarSustainPressed(true)
                } else if let captured = gesture {
                    gesture = nil
                    if studio.touchBarGestureEpoch.accepts(captured) { studio.touchBarSustainPressed(false) }
                }
            }, perform: {})
            .onDisappear {
                if let captured = gesture, studio.touchBarGestureEpoch.accepts(captured) {
                    studio.touchBarSustainPressed(false)
                }
                gesture = nil
            }
    }
}

private struct TouchBarSliderPad: View {
    @EnvironmentObject private var studio: StudioController
    let zone: TouchBarZone
    @State private var value: Double
    @State private var gesture: UInt64?

    init(zone:TouchBarZone) {
        self.zone = zone
        _value = State(initialValue:zone.initialPosition)
    }

    var body: some View {
        HStack {
            Text(zone.rawValue).frame(width: 115, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { next in
                guard studio.touchBarGestureEpoch.permitsSample(captured:gesture) else { return }
                value = next
                studio.touchBarValue(zone, normalized: next)
            }), in: 0...1, onEditingChanged: { editing in
                if editing {
                    guard gesture == nil else { return }
                    gesture = studio.touchBarGestureEpoch.revision
                    if zone == .fretless {
                        studio.touchBarKey(studio.touchBarProfile.baseNote, pressed: true, owner: .screenRibbon)
                    }
                } else if let captured = gesture {
                    gesture = nil
                    guard studio.touchBarGestureEpoch.accepts(captured) else {
                        if zone == .pitchBend || zone == .fretless { value = 0.5 }
                        return
                    }
                    if zone == .fretless {
                        studio.touchBarKey(studio.touchBarProfile.baseNote, pressed: false, owner: .screenRibbon)
                    }
                    if zone == .pitchBend || zone == .fretless {
                        value = 0.5
                        studio.touchBarValue(zone, normalized: 0.5, releaseOnly: true)
                    }
                }
            })
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 60)
        }
        .onDisappear {
            if let captured = gesture, studio.touchBarGestureEpoch.accepts(captured) {
                if zone == .fretless {
                    studio.touchBarKey(studio.touchBarProfile.baseNote, pressed:false,owner:.screenRibbon)
                }
                if zone == .pitchBend || zone == .fretless {
                    studio.touchBarValue(zone,normalized:0.5,releaseOnly:true)
                }
            }
            gesture = nil
        }
    }
}

private struct TouchBarNotePad: View {
    @EnvironmentObject private var studio: StudioController
    let note: Int
    let label: String
    @State private var isDown = false
    @State private var gesture: UInt64?

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
                        gesture = studio.touchBarGestureEpoch.revision
                        studio.touchBarKey(note, pressed: true)
                    }
                }
                .onEnded { _ in
                    if isDown {
                        release()
                    }
                }
            )
            .onDisappear { release() }
    }

    private func release() {
        let captured = gesture
        gesture = nil
        isDown = false
        if let captured, studio.touchBarGestureEpoch.accepts(captured) {
            studio.touchBarKey(note, pressed: false)
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
