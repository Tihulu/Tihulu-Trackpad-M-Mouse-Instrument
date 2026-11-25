#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore
import NoSpeakerMac

struct InstrumentBuilderView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var draft = InstrumentPatch()
    @State private var sendMIDI = false
    @State private var sendHaptics = false
    @State private var splitGamepadOutputs = false
    @State private var gamepadOutputSelection = GamepadOutputSelection()
    @State private var physical = false
    @State private var tunedAir = false
    @State private var gamepadPresetSource:SensorSource = .gamepad1
    @State private var gamepadPresetRole:GamepadFrame.Role = .lead
    @State private var gamepadPresetChannel = 3
    @State private var syntheticSource: SensorSource?
    @State private var values: [PatchSimulation.Input: Double] = [:]
    @State private var message = ""
    @State private var showPatchbay = false
    @State private var showLayout = false
    @State private var airRange = AirRangeCapture()
    @State private var drumPreset: AirDrumPreset = .snare
    @State private var remoteSource: SensorSource = .phone
    @State private var expressionPreset: MobileExpressionPreset = .major
    @State private var expressionRoot = 48
    @State private var expressionChannel = 0
    @State private var expressionCustom = "48, 50, 52, 53, 55, 57, 59, 60"
    @State private var routeSource: SensorSource?
    @State private var routeSearch = ""
    @State private var expandedRoutes: Set<String> = []
    @State private var pendingReplacement: InstrumentPatch?
    @State private var confirmReplacement = false
    @State private var pendingNativePreparation = false
    @State private var quickStart: MusicianQuickStart = .phoneDrums

    private var dirty: Bool { draft != studio.instrumentPatch }
    private var gamepadHapticAvailable: Bool {
        physical && syntheticSource == nil && !tunedAir && GamepadHapticVoices.supports(draft)
    }

    private var splitGamepadAvailable: Bool {
        gamepadHapticAvailable && Set(draft.routes.map(\.source)) == GamepadFrame.sources
    }
    private var splitGamepadValid: Bool {
        !splitGamepadOutputs || (splitGamepadAvailable &&
            GamepadOutputPlan(patch:draft,selection:gamepadOutputSelection) != nil)
    }

    private var visibleRouteIDs: Set<String> {
        Set(BuilderRouteTools.visibleIDs(in:draft,source:routeSource,query:routeSearch))
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Instrument Builder").font(.largeTitle.bold())
                Text("Create sensor-to-MIDI rules. Save your instrument, test it with simulated controls, or deliberately enable live MIDI. Native Trackpad and compatible external touch-surface input is optional and experimental.")
                    .foregroundStyle(.secondary)
                quickStartPanel { proxy.scrollTo("builder-test", anchor: .top) }
                GroupBox("Instrument") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Instrument name", text: $draft.name)
                        Text(dirty ? "Unsaved draft · retained while this app is open. Save before quitting." : "Matches saved instrument.")
                            .font(.caption).foregroundStyle(dirty ? Color.orange : Color.secondary)
                        HStack {
                            Button("Blank") { replaceDraft(with: InstrumentPatch()) }
                            Button("Expressive template") { replaceDraft(with: .starter) }
                            Button("Revert draft") { replaceDraft(with: studio.instrumentPatch) }.disabled(!dirty)
                            Button("Save changes") {
                                studio.updateInstrumentPatch(draft)
                                message = dirty ? "Could not save this instrument." : "Saved locally."
                            }.disabled(!draft.isValid || !dirty)
                            Button("Export JSON") { exportPatch() }.disabled(!draft.isValid)
                            Button("Import JSON") { importPatch() }
                            Button("Visual Patchbay") { showPatchbay = true }.buttonStyle(.borderedProminent)
                            Button("Control Layout") { showLayout = true }.disabled(draft.routes.isEmpty)
                        }
                    }.padding(8).disabled(studio.patchRunning)
                }
                GroupBox("Game controllers · Xbox / extended gamepad") {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Picker("Slot",selection:$gamepadPresetSource) {
                                Text("Controller 1").tag(SensorSource.gamepad1)
                                Text("Controller 2").tag(SensorSource.gamepad2)
                            }
                            Picker("Role",selection:$gamepadPresetRole) {
                                ForEach(GamepadFrame.Role.allCases) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            Stepper("MIDI ch \(gamepadPresetChannel+1)",value:$gamepadPresetChannel,in:0...15)
                            Button("Add mappings") {
                                var next = draft
                                next.routes += gamepadPresetRole.routes(source:gamepadPresetSource,channel:gamepadPresetChannel)
                                if next.isValid { draft = next; physical = true; message = "Choose the controller in Test instrument, release all controls, then Start." }
                                else { message = "Cannot add preset: duplicate mappings or route capacity." }
                            }
                        }
                        Text("Customize buttons, triggers and sticks in Routes. Helper has no notes or gain controls by default; use RT sustain, LT wah, left X bend and right Y modulation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(studio.patchRunning)
                GamepadMappingPanel(patch:$draft,physical:$physical).disabled(studio.patchRunning)
                GroupBox("Orchestra & Jam · ensemble templates") {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(EnsemblePreset.allCases) { preset in
                            HStack {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(preset.title).font(.headline)
                                    Text(preset.instructions).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Load template") {
                                    guard let next = preset.patch() else { message = "Invalid ensemble template."; return }
                                    replaceDraft(with:next)
                                }
                            }
                        }
                        Button("Load multi-device Party Jam") {
                            guard let next = PartyJamPreset.patch() else { message = "Invalid party template."; return }
                            replaceDraft(with:next)
                        }
                        Text("Phone drums + XY ch 10; tablet piano ch 2; Controller 1 lead ch 4; Controller 2 piano helper ch 2; Trackpad bass, Mouse pedal, lid and ribbon ch 3; camera modulation ch 4. Optional hardware may remain idle, but mapped controller slots must be explicitly bound. Multiple phones of the same role share mappings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Templates configure host-side routes only. Choose Native inputs, then start Remote TLS explicitly for mobile players. Assign separate DAW tracks to the indicated MIDI channels; no automatic playback or network listener.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(studio.patchRunning)
                ExpressivePresetPanel(patch: $draft).disabled(studio.patchRunning)
                AirHandsHelperPanel(patch: $draft, physical: $physical).disabled(studio.patchRunning)
                AirInstrumentPresetPanel(patch: $draft).disabled(studio.patchRunning)
                GroupBox("Dual Hand · camera chords") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Show a closed chord hand to arm, then 1–5 fingers to select C, Dm, Em, F or G. Open and pinch the helper hand to play; open it to release. Edit the individual note routes below.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Add dual-hand chord routes") {
                            var next = draft
                            next.routes += AirDualHandPerformance.routes()
                            if next.isValid {
                                draft = next
                                physical = true
                                message = "Dual Hand added. Enable MIDI output, grant camera permission and start explicitly."
                            } else { message = "Cannot add dual-hand routes: check route capacity." }
                        }.disabled(draft.routes.count + 15 > SensorRouter.maxMappings ||
                                    draft.routes.contains { $0.source == .camera && !AirHandsHelper.allSignals.contains($0.signal) })
                        HStack {
                            Button("Add Air Guitar · 6 strings") {
                                var next = draft
                                next.routes += AirStrumPerformance.routes(bank:AirStrumPerformance.guitarBank)
                                if next.isValid { draft = next; physical = true; message = "Select chord, pinch helper, then sweep X across strings." }
                            }.disabled(draft.routes.count + 30 > SensorRouter.maxMappings || draft.routes.contains { $0.source == .camera && !AirHandsHelper.allSignals.contains($0.signal) })
                            Button("Replace with 3-course Air") {
                                replaceDraft(with:.init(name:"Air three-course strings",routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank)))
                            }
                            Button("Add 3-course Air · experimental") {
                                var next = draft
                                next.routes += AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank)
                                if next.isValid { draft = next; physical = true; message = "Three-course equal-tempered preset; not makam tuning." }
                            }.disabled(draft.routes.count + 15 > SensorRouter.maxMappings || draft.routes.contains { $0.source == .camera && !AirHandsHelper.allSignals.contains($0.signal) })
                        }
                        if AirStrumPerformance.usesStrum(draft.routes) {
                            Text("Pinch arms the stroke; sweep X to cross virtual strings. Opening the pinch releases all string pulses. Edit each string note in Routes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Add helper effects · Bend / Expression / Wah") {
                            var next = draft
                            next.routes += AirDualHandPerformance.helperRoutes()
                            if next.isValid {
                                draft = next
                                message = "Helper effects added. X = bend, Y = expression, aperture = CC74. Assign these in your DAW."
                            } else { message = "Cannot add helper effects: check route capacity, duplicate IDs and release settings." }
                        }.disabled(draft.routes.count + 3 > SensorRouter.maxMappings ||
                                    !AirDualHandPerformance.usesDualCamera(draft.routes) ||
                                    AirDualHandPerformance.hasHelperRoutes(draft.routes))
                        Text("Optional helper axes remain active after opening the pinch while a valid chord is selected. Tracking loss releases all camera-owned controls. Customize targets, ranges and smoothing in Routes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Swap physical chord and helper hands", isOn: $studio.patchCameraSwapRoles)
                        Text("Experimental live camera mode; connect a DAW to the dedicated Builder MIDI output. Simulation routes remain available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(studio.patchRunning)
                }
                GroupBox("Air Drums · motion percussion") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Device", selection: $remoteSource) {
                                Text("Phone").tag(SensorSource.phone)
                                Text("Tablet").tag(SensorSource.tablet)
                            }
                            Picker("Drum", selection: $drumPreset) {
                                ForEach(AirDrumPreset.allCases) { Text($0.label).tag($0) }
                            }
                            Button("Add drum route") { addDrumRoute() }
                                .disabled(draft.routes.count >= SensorRouter.maxMappings)
                        }
                        Text("General MIDI channel 10 defaults. Enable acceleration in the paired browser to play. Add one drum per source, or deliberately layer notes using identical strike sensitivity. Map to a drum instrument in your DAW.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(studio.patchRunning)
                }
                GroupBox("Mobile instruments") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Device", selection: $remoteSource) {
                            Text("Phone").tag(SensorSource.phone)
                            Text("Tablet").tag(SensorSource.tablet)
                        }
                        Text("\(max(0, SensorRouter.maxMappings - draft.routes.count)) routes available · Existing mappings and labels are preserved.")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ForEach(BuilderRouteTools.MobilePreset.allCases) { preset in
                            let missing = preset.missingCount(in:draft,source:remoteSource)
                            let remaining = SensorRouter.maxMappings - draft.routes.count
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                    Text("\(preset.signals.count - missing)/\(preset.signals.count) mapped" + (missing > remaining ? " · Not enough route slots" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(missing == 0 ? "Mapped" : "Add \(missing) missing") { addMobilePreset(preset) }
                                    .disabled(missing == 0 || missing > remaining || !draft.isValid)
                            }
                        }
                        Text("Defaults: drums on channel 10; piano and pedalboard on channel 1. Customize all targets in Routes. Scale guidance requires a verified default mapping; motion wah and manual wah can share a parameter only deliberately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(studio.patchRunning)
                }
                expressionPresetPanel.disabled(studio.patchRunning)
                GroupBox("Routes · \(draft.routes.count)/64") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Source filter", selection: $routeSource) {
                                Text("All sources").tag(nil as SensorSource?)
                                ForEach(SensorSource.allCases, id: \.self) { source in
                                    Text(source.rawValue).tag(Optional(source))
                                }
                            }
                            TextField("Search signal, MIDI target or label", text: $routeSearch)
                            Button("Clear filter") { routeSource = nil; routeSearch = "" }
                        }
                        let visible = visibleRouteIDs
                        Text("\(visible.count) of \(draft.routes.count) routes shown · Filters do not change the instrument.")
                            .font(.caption).foregroundStyle(.secondary)
                        if visible.isEmpty && !draft.routes.isEmpty {
                            Text("No matching routes. Clear the filter to see all mappings.").font(.caption)
                        }
                        Button("Collapse all routes") { expandedRoutes.removeAll() }.controlSize(.small)
                        ForEach($draft.routes) { $route in
                            if visible.contains(route.id) {
                                let id = route.id
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expandedRoutes.contains(id) },
                                    set: { expanded in
                                        if expanded { expandedRoutes.insert(id) } else { expandedRoutes.remove(id) }
                                    })) {
                                    routeEditor($route)
                                    Button("Remove route", role: .destructive) {
                                        expandedRoutes.remove(id)
                                        draft.routes.removeAll { $0.id == id }
                                    }.font(.caption)
                                } label: {
                                    Text(BuilderRouteTools.summary(route))
                                        .foregroundStyle(InstrumentPatch.permits(route) ? Color.primary : Color.orange)
                                }
                                Divider()
                            }
                        }
                        Button("Add Pocket Wah route (Phone · CC74)") {
                            var next = draft
                            next.routes.append(.init(id: UUID().uuidString, source: .phone, signal: .tiltPitch,
                                                     destination: .init(.controlChange, number: 74),
                                                     response: .init(smoothingMS: 35)))
                            if next.isValid { draft = next; message = "Pocket Wah route added. Map CC74 to a wah/filter parameter in your DAW." }
                            else { message = "Cannot add route: check capacity and release-value conflicts." }
                        }.disabled(draft.routes.count >= SensorRouter.maxMappings || draft.routes.contains { $0.source == .phone && $0.signal == .tiltPitch && $0.destination == .init(.controlChange, number: 74) })
                        Button("Add Air Whammy route (Phone · Pitch Bend)") {
                            var next = draft
                            next.routes.append(.init(id: UUID().uuidString, source: .phone, signal: .tiltRoll,
                                                     destination: .init(.pitchBend), response: .init(smoothingMS: 20)))
                            if next.isValid { draft = next; message = "Air Whammy route added. Set the pitch-bend range on your DAW instrument." }
                            else { message = "Cannot add route: check capacity and release-value conflicts." }
                        }.disabled(draft.routes.count >= SensorRouter.maxMappings || draft.routes.contains { $0.source == .phone && $0.signal == .tiltRoll && $0.destination == .init(.pitchBend) })
                        Button("Add route") {
                            draft.routes.append(.init(id: UUID().uuidString, source: .trackpad,
                                                     signal: .contact, destination: .init(.note, number: 60)))
                        }.disabled(draft.routes.count >= SensorRouter.maxMappings)
                        if !draft.isValid {
                            Text("Correct invalid names, calibration, thresholds, reserved CC numbers, conflicting release values or Air Drums sensitivity before saving.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(8).disabled(studio.patchRunning)
                }
                GroupBox("Test instrument") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Input", selection: $physical) {
                            Text("Simulation").tag(false)
                            Text("Native inputs (experimental)").tag(true)
                        }.pickerStyle(.segmented).disabled(studio.patchRunning)
                        if physical {
                            Picker("Synthetic source (Hybrid)",selection:$syntheticSource) {
                                Text("None · native only").tag(nil as SensorSource?)
                                ForEach([SensorSource.trackpad,.magicMouse,.touchBar,.lid,.external,.camera],id:\.self) { source in
                                    if draft.routes.contains(where: { $0.source == source }) {
                                        Text(source.rawValue + " · on-screen").tag(Optional(source))
                                    }
                                }
                            }.disabled(studio.patchRunning)
                            .onChange(of:syntheticSource) { _ in if !studio.patchRunning { sendMIDI = false } }
                            if syntheticSource != nil {
                                Text("Only the selected source is simulated. Other sources are native. Leaving this page releases simulated controls; a stalled UI lease expires in 350 ms. For paired phone/tablet routes, start through the Remote TLS panel.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if physical && draft.routes.contains(where:{GamepadFrame.sources.contains($0.source)}) {
                            GroupBox("Bind paired gamepads") {
                                VStack(alignment:.leading,spacing:6) {
                                    Button("Refresh connected controllers") { studio.refreshBuilderGamepads() }
                                    if draft.routes.contains(where:{$0.source == .gamepad1}) {
                                        Picker("Controller 1",selection:$studio.gamepadSlot1) {
                                            Text("Select controller").tag(nil as UUID?)
                                            ForEach(studio.gamepadChoices) { Text($0.name).tag(Optional($0.id)) }
                                        }
                                    }
                                    if draft.routes.contains(where:{$0.source == .gamepad2}) {
                                        Picker("Controller 2",selection:$studio.gamepadSlot2) {
                                            Text("Select controller").tag(nil as UUID?)
                                            ForEach(studio.gamepadChoices) { Text($0.name).tag(Optional($0.id)) }
                                        }
                                    }
                                    Text("Pair in macOS Bluetooth settings first. Release all buttons, triggers and sticks to arm. Disconnect releases only that slot; restart to bind a replacement. Native change callbacks plus watchdog; very short physical taps still need hardware verification.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(6).disabled(studio.patchRunning)
                            }
                        }
                        gamepadOutputPanel
                        dawRoutingPanel
                        if AirStrumPerformance.usesStrum(draft.routes) || tunedAir {
                            Toggle("Tune Air strings from current Custom Scale (MPE)",isOn:$tunedAir)
                                .disabled(studio.patchRunning)
                            if tunedAir {
                                Text("Dedicated TIHULU Air Strings MPE port. Camera strings and supported master effects, one logical MIDI channel, up to 15 distinct notes. Explicit MIDI output required. No Hybrid/Remote. Armed recording preserves MPE setup and effects. The current bank root and offsets are frozen at Start.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if physical && syntheticSource != .camera && draft.routes.contains(where: { $0.source == .camera }) {
                            DisclosureGroup("Camera setup") {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Picker("Camera", selection: $studio.patchCameraDeviceID) {
                                            Text("System default").tag("")
                                            if !studio.patchCameraDeviceID.isEmpty &&
                                                !studio.patchCameraChoices.contains(where: { $0.id == studio.patchCameraDeviceID }) {
                                                Text("Selected camera unavailable").tag(studio.patchCameraDeviceID)
                                            }
                                            ForEach(studio.patchCameraChoices) { Text($0.name).tag($0.id) }
                                        }
                                        Button("Refresh") { studio.refreshBuilderCameras() }
                                    }
                                    Picker("Control orientation", selection: $studio.patchCameraOrientation) {
                                        ForEach(AirControlOrientation.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    Toggle("Mirror horizontal control", isOn: $studio.patchCameraMirrorX)
                                    Text("Rotates the derived X/Y controls only. Recalibrate after changing camera or orientation. Selection stays local to this app session.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.disabled(studio.patchRunning)
                            }
                        }
                        if physical && draft.routes.contains(where: { $0.source == .phone || $0.source == .tablet }) {
                            if tunedAir {
                                Text("Turn off tuned Air explicitly before starting Remote, or use a string-only patch.").font(.caption).foregroundStyle(.orange)
                            } else {
                                RemoteLoopbackPanel(patch: draft, sendMIDI: sendMIDI, syntheticSource:syntheticSource)
                            }
                        }
                        if physical && !(syntheticSource.map { PhysicalPatchRuntime.supportsHybrid(draft,synthetic:$0) } ?? PhysicalPatchRuntime.supports(draft)) {
                            Text("Normal native mode supports local surfaces, lid, ribbon and camera. For valid phone/tablet touch, piano, drum pads, pedalboard and motion routes, use the Remote panel above. Other unsupported signals remain simulation-only.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Start test") {
                                studio.updateInstrumentPatch(draft)
                                values = [:]
                                airRange = AirRangeCapture(signal: airRange.signal)
                                studio.startInstrumentPatch(sendMIDI: sendMIDI, physical: physical,synthetic:physical ? syntheticSource : nil,tunedAir:tunedAir,sendHaptics:gamepadHapticAvailable && sendHaptics,
                                    gamepadOutputSelection:splitGamepadOutputs ? gamepadOutputSelection : nil)
                            }.buttonStyle(.borderedProminent)
                                 .disabled(studio.patchRunning || !draft.isValid || draft.routes.isEmpty || !splitGamepadValid || (physical && !(syntheticSource.map { PhysicalPatchRuntime.supportsHybrid(draft,synthetic:$0) } ?? PhysicalPatchRuntime.supports(draft))))
                            Button("Stop / Release All") { studio.stopInstrumentPatch() }
                            Spacer()
                            Text(studio.patchStatus).font(.caption)
                        }
                        EnsembleTakePanel()
                        if studio.patchRunning { EnsembleClockPanel() }
                        else if studio.ensembleClockStatus.contains("Stop delivery failed") {
                            HStack {
                                Text(studio.ensembleClockStatus).font(.caption).foregroundStyle(.orange)
                                Button("Retry clock Stop") { studio.stopEnsembleClock() }
                            }
                        }
                        if studio.patchRunning && (!studio.patchPhysical || studio.patchHybridSource != nil) {
                            if studio.patchAirDebugAvailable { AirDualDebugPanel() }
                            if studio.patchHelperDebugAvailable { AirHandsHelperDebugPanel() }
                            if studio.patchHybridSource != nil && studio.patchHybridSource != .camera {
                                Button("Release all synthetic controls") {
                                    studio.releaseHybridControls()
                                    values = [:]
                                }
                            }
                            PerformanceControlsView(patch: studio.instrumentPatch, values: $values)
                        }
                        if studio.patchRunning && studio.patchNativeBar, let token = studio.builderBarToken {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Builder ribbon · native Touch Bar / on-screen fallback").font(.headline)
                                Slider(value: Binding(get: { values[.init(source: .touchBar, signal: .x)] ?? 0.5 },
                                                      set: { value in
                                    values[.init(source: .touchBar, signal: .x)] = value
                                    studio.builderBarValue(value, token: token)
                                }), in: 0...1, onEditingChanged: { editing in
                                    if !editing { studio.builderBarValue(nil, token: token) }
                                })
                                Button("Release ribbon") { studio.builderBarValue(nil, token: token) }
                                Text("No native hardware detection claim. Inactive samples release after 350 ms.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if physical && draft.routes.contains(where: { $0.source == .camera }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(studio.patchCameraStatus).font(.headline)
                                if studio.patchAirRecordAvailable {
                                    Text("Selected slot: " + (studio.patchAirLiveSelected.map { String($0) } ?? "—") + " · Sounding: " + (studio.patchAirLiveSounding.map { String($0) } ?? "—"))
                                        .font(.caption.monospacedDigit())
                                    HStack {
                                        Button("Record diagnostic trace") { studio.startAirTrace() }.disabled(studio.patchAirRecording)
                                        Button("Stop recording") { studio.stopAirTrace() }.disabled(!studio.patchAirRecording)
                                        Text("\(studio.patchAirTraceCount) frames").font(.caption.monospacedDigit())
                                    }
                                    Text("Opt-in, in-memory derived hand coordinates only. Up to 30 seconds / 600 frames. Replay in Simulation mode after stopping live input.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(AirDualHandPerformance.usesDualCamera(draft.routes) ?
                                     (AirStrumPerformance.usesStrum(draft.routes) ?
                                      "Dual hand strings: close chord hand to arm, select 1–5 fingers, pinch helper and sweep X. Open pinch to release all strings." :
                                      "Dual hand: close chord hand to arm, select 1–5 fingers, pinch helper to play. Open pinch to release notes. Optional helper axes remain active with a valid selection.") :
                                     "Show one hand: X/Y are index fingertip position, gesture is thumb/index aperture relative to palm length, contact is reliable hand presence. Camera permission is required. No image recording or network.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let hand = studio.patchCameraHand {
                                    HStack {
                                        Text("X"); ProgressView(value: hand.x)
                                        Text("Y"); ProgressView(value: hand.y)
                                        Text("Aperture"); ProgressView(value: hand.aperture)
                                    }.font(.caption)
                                }
                                AirCalibrationPanel(patch: $draft, capture: $airRange)
                            }
                        }
                        if physical && draft.routes.contains(where: { $0.source == .lid }) {
                            Text(studio.patchLidStatus + (studio.patchLidDegrees.map { String(format: " · %.1f°", $0) } ?? ""))
                                .font(.caption)
                            Text("Lid angle is normalized from 5–175°. Use input calibration to limit the sweep to a comfortable range. Do not force or repeatedly move the lid.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if physical {
                            Text("Primary contact per surface; contact size is not measured pressure. The private macOS driver groups compatible external touch surfaces under Magic Mouse; device identity is not verified here. The shared monitor supports independent Touch Instrument and MIDI Helper sessions; route the dedicated MIDI source separately in the DAW. Lift or loss of input releases owned controls. No automatic pointer capture.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Use " + (tunedAir ? "TIHULU Air Strings MPE" : "TIHULU Instrument Builder") + " as a dedicated DAW input if MIDI is enabled. Connect a separate instrument/channel. Stop or Panic releases owned controls. Physical sessions continue across pages; simulation ends when leaving. Remote starts only explicitly; LAN requires a successful Mac-only diagnostic and trusted certificate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.id("builder-test")
                GroupBox("Command monitor") {
                    VStack(alignment: .leading, spacing: 4) {
                        if studio.patchTunedAirActive {
                            Text("Logical router commands (before MPE channel translation). Verify wire channels and pitch bends in your DAW MIDI monitor.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(studio.patchMessages.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.system(.caption, design: .monospaced))
                        }
                        if studio.patchMessages.isEmpty { Text("Move an input after starting the test.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        }
        .sheet(isPresented: $showPatchbay) { VisualPatchbayView(patch: $draft) }
        .sheet(isPresented: $showLayout) { PerformanceLayoutEditor(patch: $draft) }
        .confirmationDialog("Replace unsaved instrument draft?", isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button("Replace draft", role: .destructive) {
                if !studio.patchRunning, let replacement = pendingReplacement {
                    applyReplacement(replacement)
                    if pendingNativePreparation { prepareNativeInput() }
                }
                pendingReplacement = nil
                pendingNativePreparation = false
            }
            Button("Cancel", role: .cancel) {
                pendingReplacement = nil
                pendingNativePreparation = false
            }
        } message: {
            Text("Unsaved routes, labels and settings in the current draft will be replaced. The saved instrument is unchanged until Save or Start.")
        }
        .onAppear {
            draft = studio.resumeBuilderDraft()
            if studio.patchRunning {
                physical = studio.patchPhysical; sendMIDI = studio.patchMIDIEnabled
                sendHaptics = studio.patchHapticEnabled; syntheticSource = studio.patchHybridSource
                tunedAir = studio.patchTunedAirActive
                splitGamepadOutputs = studio.patchGamepadOutputSelection != nil
                if let selection = studio.patchGamepadOutputSelection { gamepadOutputSelection = selection }
            }
        }
        .onChange(of:gamepadHapticAvailable) { available in
            if !available && !studio.patchRunning { sendHaptics = false }
        }
        .onChange(of:splitGamepadAvailable) { available in
            if !available && !studio.patchRunning { splitGamepadOutputs = false }
        }
        .task(id:studio.patchHybridRunID) {
            guard let runID = studio.patchHybridRunID else { return }
            while !Task.isCancelled && studio.patchRunning && studio.patchHybridRunID == runID {
                do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                studio.refreshHybridControls(runID:runID)
            }
        }
        .onDisappear {
            studio.stopEnsembleClock()
            if !studio.patchPhysical { studio.stopInstrumentPatch() }
            else { studio.releaseHybridControls() }
            studio.rememberBuilderDraft(draft)
        }
    }

    private var dawRoutingPanel: some View {
        let rows = DAWRoutingOverview.rows(for:draft)
        return DisclosureGroup("DAW routing · Logic track setup") {
            VStack(alignment:.leading,spacing:6) {
                Text(tunedAir ? "Tuned Air uses a dedicated MPE port. The rows below are logical routes, not MPE member channels." :
                    "Standard Builder MIDI port: TIHULU Instrument Builder. These are logical routes; only enabled MIDI outputs reach the DAW.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    VStack(alignment:.leading,spacing:2) {
                        Text("Channel \(row.channel+1)").font(.headline)
                        Text("Notes: " + (row.noteSources.isEmpty ? "—" : row.noteSources.map(\.rawValue).joined(separator:", "))).font(.caption)
                        Text("Controls: " + (row.controlSources.isEmpty ? "—" : row.controlSources.map(\.rawValue).joined(separator:", "))).font(.caption)
                        if row.sharesNotes {
                            Text("Shared note channel: these sources play the same receiving instrument. Separate channels for different instruments.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if rows.isEmpty { Text("Add valid mappings first.").font(.caption) }
                Text("In Logic, create one Software Instrument track per desired sound. Set Track Inspector MIDI Input and MIDI In Channel, record-enable each track, then test one controller at a time. Controls-only sources can intentionally share a target.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy logical routing summary") {
                    let header = tunedAir ? "Logical routes only — Tuned Air MPE" : "TIHULU Instrument Builder — logical routes; check enabled MIDI outputs"
                    let report = rows.map { row in
                        "Ch \(row.channel+1) | notes: \(row.noteSources.map(\.rawValue).joined(separator:", ")) | controls: \(row.controlSources.map(\.rawValue).joined(separator:", "))"
                    }.joined(separator:"\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(header+"\n"+report,forType:.string)
                }.disabled(rows.isEmpty)
            }.padding(6)
        }
    }

    private var gamepadOutputPanel: some View {
        VStack(alignment:.leading,spacing:6) {
            if splitGamepadAvailable {
                Toggle("Separate outputs for each controller",isOn:$splitGamepadOutputs)
                    .disabled(studio.patchRunning)
                    .onChange(of:splitGamepadOutputs) { enabled in
                        if !enabled && !studio.patchRunning { sendMIDI = false; sendHaptics = false }
                    }
            }
            if splitGamepadOutputs && splitGamepadAvailable {
                Picker("Controller 1 output",selection:$gamepadOutputSelection.slot1) {
                    ForEach(MusicalOutput.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(studio.patchRunning)
                Picker("Controller 2 output",selection:$gamepadOutputSelection.slot2) {
                    ForEach(MusicalOutput.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(studio.patchRunning)
                if !splitGamepadValid {
                    Text("Different outputs cannot share a MIDI channel. Change one controller's channel in its mapping editor.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Output selection is frozen at Start. A controller's effects and sustain use its assigned MIDI channels.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Send controls to dedicated MIDI output",isOn:$sendMIDI)
                    .disabled(studio.patchRunning)
                if gamepadHapticAvailable {
                    Toggle("Play notes on Force Touch Trackpad",isOn:$sendHaptics)
                        .disabled(studio.patchRunning)
                    Text(sendHaptics ? (sendMIDI ? "Both · dedicated DAW MIDI + Trackpad" : "Trackpad only · no outgoing MIDI") : (sendMIDI ? "MIDI only" : "Monitor only · no sound output"))
                        .font(.caption.weight(.semibold))
                }
            }
            if gamepadHapticAvailable {
                Text("Trackpad renders up to six folded tones; sustain, pitch bend (±2 semitones), CC7 and CC11 are supported. Other CCs are DAW controls, not local effects. Stop competing haptic sessions first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var expressionPresetPanel: some View {
        GroupBox("Mobile Expression · note zones") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Device", selection: $remoteSource) {
                    Text("Phone").tag(SensorSource.phone)
                    Text("Tablet").tag(SensorSource.tablet)
                }
                Picker("Notes", selection: $expressionPreset) {
                    ForEach(MobileExpressionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                if expressionPreset == .custom {
                    TextField("1–25 MIDI notes, 0–127", text: $expressionCustom)
                    Text("Enter notes in your preferred left-to-right order. Repeated notes are allowed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper("Root MIDI note \(expressionRoot)", value: $expressionRoot, in: 0...115)
                }
                Stepper("MIDI channel \(expressionChannel + 1)", value: $expressionChannel, in: 0...15)
                let notes = expressionPreset.notes(root: expressionRoot, custom: expressionCustom)
                let hasExisting = draft.routes.contains {
                    $0.source == remoteSource && RemotePiano.signals.contains($0.signal)
                }
                if let notes {
                    Text("Notes: " + notes.map { String($0) }.joined(separator: ", "))
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Invalid note list. Use 1–25 MIDI notes between 0 and 127.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if hasExisting {
                    Text("This device already has piano or note-zone mappings. Edit them in Routes, or use another device or a new draft.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Add note zones + sustain") {
                    do {
                        draft = try expressionPreset.appending(to: draft, source: remoteSource,
                            channel: expressionChannel, root: expressionRoot, custom: expressionCustom)
                        routeSource = remoteSource
                        routeSearch = ""
                        physical = true
                        message = "Note zones added. Pair in Play setup; choose Note strips on the mobile page."
                    } catch {
                        message = "Cannot add note zones: check existing mappings and route capacity."
                    }
                }.disabled(hasExisting || !draft.isValid || notes == nil ||
                            (notes?.count ?? 0) + 1 > SensorRouter.maxMappings - draft.routes.count)
                Text("Discrete MIDI notes, fixed velocity. The paired browser can use piano or note strips. Independent pitch bend, microtonal tuning and MPE are not available in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private func quickStartPanel(openSetup: @escaping () -> Void) -> some View {
        GroupBox("Quick start · choose how to play") {
            VStack(alignment: .leading, spacing: 8) {
                if studio.patchRunning {
                    Text(studio.patchStatus).font(.headline)
                    Button("Stop / Release All") { studio.stopInstrumentPatch() }
                } else {
                    Picker("Play style", selection: $quickStart) {
                        ForEach(MusicianQuickStart.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Text(quickStart.instructions).foregroundStyle(.secondary)
                    Button("Prepare instrument") {
                        guard let patch = quickStart.patch() else {
                            message = "This template is not available."
                            return
                        }
                        replaceDraft(with: patch, prepareNative: true)
                    }.buttonStyle(.borderedProminent)
                    Text("Prepares an editable draft with native input selected and MIDI output off. Pair devices, enable MIDI and start explicitly in Play setup. Advanced routes remain editable below.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.caption) }
                }
                Button("Go to play setup", action: openSetup)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func routeEditor(_ route: Binding<SensorMapping>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if route.wrappedValue.pedalMode != nil {
                Text("\(route.wrappedValue.source.rawValue) · \(GamepadMappingEditor.label(route.wrappedValue.signal))")
                    .font(.headline)
                Picker("Pedal behavior",selection:route.pedalMode) {
                    Text("Hold").tag(Optional(GamepadPedalMode.hold))
                    Text("Toggle").tag(Optional(GamepadPedalMode.toggle))
                }
                Stepper("Channel \(route.wrappedValue.destination.channel+1)",value:route.destination.channel,in:0...15)
                if route.wrappedValue.destination.kind == .controlChange {
                    Stepper("Effect CC \(route.wrappedValue.destination.number)",value:route.destination.number,in:0...119)
                } else {
                    Text("Sustain · CC64").font(.caption)
                }
                parameter("Press threshold",value:route.threshold,range:0.05...1)
                parameter("Hysteresis",value:route.hysteresis,range:0...0.5)
                if !InstrumentPatch.permits(route.wrappedValue) {
                    Text("Invalid pedal target or threshold. Correct the route before saving or starting.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Binary effect switches share ownership. Analog calibration and smoothing do not apply. Use the gamepad map to change the physical control or destination type.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Convert to ordinary route") { route.wrappedValue.pedalMode = nil }
            } else {
            HStack {
                Picker("Source", selection: route.source) {
                    ForEach(SensorSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Signal", selection: route.signal) {
                    ForEach(SensorSignal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Image(systemName: "arrow.right")
                Picker("Output", selection: Binding(get: { route.wrappedValue.destination.kind }, set: { kind in
                    route.wrappedValue.destination.kind = kind
                    route.wrappedValue.response = nil
                    route.wrappedValue.destination.number = kind == .note ? 60 : (kind == .controlChange ? 74 : 0)
                })) {
                    ForEach(SensorDestinationKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Stepper("Channel \(route.wrappedValue.destination.channel + 1)", value: route.destination.channel, in: 0...15)
                if route.wrappedValue.destination.kind == .note || route.wrappedValue.destination.kind == .controlChange {
                    Stepper("Number \(route.wrappedValue.destination.number)", value: route.destination.number,
                            in: 0...(route.wrappedValue.destination.kind == .note ? 127 : 119))
                }
                Stepper("Priority \(route.wrappedValue.priority)", value: route.priority, in: -100...100)
            }
            if ContinuousResponse.isContinuous(route.wrappedValue.destination) {
                ContinuousResponsePanel(response: route.response, target: route.wrappedValue.destination)
            }
            DisclosureGroup(route.wrappedValue.signal == .airStrike ? "Strike sensitivity & velocity" : "Calibration & gate") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Invert", isOn: route.calibration.inverted)
                    parameter("Minimum", value: route.calibration.minimum, range: 0...1)
                    parameter("Maximum", value: route.calibration.maximum, range: 0...1)
                    parameter("Dead zone", value: route.calibration.deadZone, range: 0...0.45)
                    parameter("Curve exponent", value: route.calibration.exponent, range: 0.25...4)
                    if route.wrappedValue.signal == .airStrike {
                        parameter("Strike threshold", value: route.threshold, range: 0.10...0.95)
                        parameter("Reset gap", value: route.hysteresis, range: 0.05...0.5)
                        Text("Reset threshold: \(max(0, route.wrappedValue.threshold - route.wrappedValue.hysteresis), specifier: "%.2f") · Quiet 80 ms · Retrigger 120 ms")
                            .font(.caption)
                        Stepper("Velocity ceiling \(route.wrappedValue.velocity)", value: route.velocity, in: 1...127)
                        Text("Calibration and curve shape velocity, not onset detection. All strike routes for this source must agree on threshold and reset gap.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if route.wrappedValue.destination.kind == .note || route.wrappedValue.destination.kind == .sustain {
                        parameter("Threshold", value: route.threshold, range: 0.05...1)
                        parameter("Hysteresis", value: route.hysteresis, range: 0...0.5)
                        Stepper("Note velocity \(route.wrappedValue.velocity)", value: route.velocity, in: 1...127)
                    }
                }.padding(4)
            }
            }
        }
    }

    private func addMobilePreset(_ preset: BuilderRouteTools.MobilePreset) {
        let count = preset.missingCount(in:draft,source:remoteSource)
        do {
            draft = try preset.appending(to:draft,source:remoteSource)
            message = count == 0 ? "All controls already mapped." : "Added \(count) missing routes for \(remoteSource.rawValue)."
            routeSource = remoteSource
            routeSearch = ""
        } catch { message = "Cannot add preset: check route capacity, invalid mappings or shared release values." }
    }

    private func addDrumRoute() {
        var next = draft
        var route = drumPreset.route(source: remoteSource)
        if let existing = next.routes.first(where: { $0.source == remoteSource && $0.signal == .airStrike }) {
            route.threshold = existing.threshold
            route.hysteresis = existing.hysteresis
        }
        guard !next.routes.contains(where: { $0.source == route.source && $0.signal == .airStrike && $0.destination == route.destination }) else {
            message = "That drum is already mapped for this source."; return
        }
        next.routes.append(route)
        guard next.isValid else { message = "Cannot add drum: correct existing routes first."; return }
        draft = next
        message = "Air Drums route added. Enable acceleration on the paired device."
    }

    private func parameter(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 125, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 55)
        }
    }

    private func replaceDraft(with replacement: InstrumentPatch, prepareNative: Bool = false) {
        guard !studio.patchRunning else { return }
        if draft == replacement {
            if prepareNative { prepareNativeInput() }
            return
        }
        if dirty {
            pendingReplacement = replacement
            pendingNativePreparation = prepareNative
            confirmReplacement = true
        } else {
            applyReplacement(replacement)
            if prepareNative { prepareNativeInput() }
        }
    }

    private func prepareNativeInput() {
        physical = true
        syntheticSource = nil
        sendMIDI = false
        tunedAir = false
        message = "Ready for setup. MIDI output is off. Pair devices and start explicitly."
    }

    private func applyReplacement(_ replacement: InstrumentPatch) {
        draft = replacement
        tunedAir = false
        expandedRoutes.removeAll()
        routeSource = nil
        routeSearch = ""
        if replacement == studio.instrumentPatch { studio.discardBuilderDraft() }
        message = replacement == studio.instrumentPatch ? "Restored saved instrument." : "Draft replaced. Save changes or Start test to use it."
    }

    private func exportPatch() {
        do {
            let data = try draft.archive()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "TIHULU Instrument.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            message = "Exported instrument."
        } catch { message = error.localizedDescription }
    }

    private func importPatch() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, !studio.patchRunning else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: WorkspaceArchive.maximumBytes + 1) ?? Data()
            replaceDraft(with: try InstrumentPatch.read(data))
        } catch { message = error.localizedDescription }
    }
}
#endif
