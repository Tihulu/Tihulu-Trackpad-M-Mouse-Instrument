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
    @State private var physical = false
    @State private var values: [PatchSimulation.Input: Double] = [:]
    @State private var message = ""
    @State private var showPatchbay = false
    @State private var showLayout = false
    @State private var airRange = AirRangeCapture()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Instrument Builder").font(.largeTitle.bold())
                Text("Create sensor-to-MIDI rules. Save your instrument, test it with simulated controls, or deliberately enable live MIDI. Native Trackpad and compatible external touch-surface input is optional and experimental.")
                    .foregroundStyle(.secondary)
                GroupBox("Instrument") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Instrument name", text: $draft.name)
                        HStack {
                            Button("Blank") { draft = InstrumentPatch() }
                            Button("Expressive template") { draft = .starter }
                            Button("Save changes") { studio.updateInstrumentPatch(draft); message = "Saved locally." }
                                .disabled(!draft.isValid)
                            Button("Export JSON") { exportPatch() }.disabled(!draft.isValid)
                            Button("Import JSON") { importPatch() }
                            Button("Visual Patchbay") { showPatchbay = true }.buttonStyle(.borderedProminent)
                            Button("Control Layout") { showLayout = true }.disabled(draft.routes.isEmpty)
                        }
                    }.padding(8).disabled(studio.patchRunning)
                }
                ExpressivePresetPanel(patch: $draft).disabled(studio.patchRunning)
                AirInstrumentPresetPanel(patch: $draft).disabled(studio.patchRunning)
                GroupBox("Routes · \(draft.routes.count)/64") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($draft.routes) { $route in
                            routeEditor($route)
                            Button("Remove route", role: .destructive) {
                                draft.routes.removeAll { $0.id == route.id }
                            }.font(.caption)
                            Divider()
                        }
                        Button("Add Pocket Wah route (Phone · CC74)") {
                            var next = draft
                            next.routes.append(.init(id: UUID().uuidString, source: .phone, signal: .tiltPitch,
                                                     destination: .init(.controlChange, number: 74),
                                                     response: .init(smoothingMS: 35)))
                            if next.isValid { draft = next; message = "Pocket Wah route added. Map CC74 to a wah/filter parameter in your DAW." }
                            else { message = "Cannot add route: check capacity and release-value conflicts." }
                        }.disabled(draft.routes.count >= SensorRouter.maxMappings || draft.routes.contains { $0.source == .phone && $0.signal == .tiltPitch && $0.destination == .init(.controlChange, number: 74) })
                        Button("Add route") {
                            draft.routes.append(.init(id: UUID().uuidString, source: .trackpad,
                                                     signal: .contact, destination: .init(.note, number: 60)))
                        }.disabled(draft.routes.count >= SensorRouter.maxMappings)
                        if !draft.isValid {
                            Text("Correct invalid names, calibration, thresholds, reserved CC numbers or conflicting release values before saving.")
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
                        Toggle("Send controls to dedicated MIDI output", isOn: $sendMIDI)
                            .disabled(studio.patchRunning)
                        if physical && draft.routes.contains(where: { $0.source == .camera }) {
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
                            RemoteLoopbackPanel(patch: draft, sendMIDI: sendMIDI)
                        }
                        if physical && !PhysicalPatchRuntime.supports(draft) {
                            Text("Normal native mode supports local surfaces, lid, ribbon and camera. For mapped phone/tablet X/Y/contact or tilt CC/pitch bend use the separate Remote panel above. Other remote signals remain simulation-only.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Start test") {
                                studio.updateInstrumentPatch(draft)
                                values = [:]
                                airRange = AirRangeCapture(signal: airRange.signal)
                                studio.startInstrumentPatch(sendMIDI: sendMIDI, physical: physical)
                            }.buttonStyle(.borderedProminent)
                                .disabled(studio.patchRunning || !draft.isValid || draft.routes.isEmpty || (physical && !PhysicalPatchRuntime.supports(draft)))
                            Button("Stop / Release All") { studio.stopInstrumentPatch() }
                            Spacer()
                            Text(studio.patchStatus).font(.caption)
                        }
                        if studio.patchRunning && !studio.patchPhysical {
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
                                Text("Show one hand: X/Y are index fingertip position, gesture is thumb/index aperture relative to palm length, contact is reliable hand presence. Camera permission is required. No image recording or network.")
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
                        Text("Use TIHULU Instrument Builder as a dedicated DAW input if MIDI is enabled. Connect a separate instrument/channel. Stop or Panic releases owned controls. Physical sessions continue across pages; simulation ends when leaving. Remote starts only explicitly; LAN requires a successful Mac-only diagnostic and trusted certificate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Command monitor") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(studio.patchMessages.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.system(.caption, design: .monospaced))
                        }
                        if studio.patchMessages.isEmpty { Text("Move an input after starting the test.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .sheet(isPresented: $showPatchbay) { VisualPatchbayView(patch: $draft) }
        .sheet(isPresented: $showLayout) { PerformanceLayoutEditor(patch: $draft) }
        .onAppear {
            draft = studio.instrumentPatch
            if studio.patchRunning { physical = studio.patchPhysical; sendMIDI = studio.patchMIDIEnabled }
        }
        .onDisappear {
            if !studio.patchPhysical { studio.stopInstrumentPatch() }
        }
    }

    private func routeEditor(_ route: Binding<SensorMapping>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
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
            DisclosureGroup("Calibration & gate") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Invert", isOn: route.calibration.inverted)
                    parameter("Minimum", value: route.calibration.minimum, range: 0...1)
                    parameter("Maximum", value: route.calibration.maximum, range: 0...1)
                    parameter("Dead zone", value: route.calibration.deadZone, range: 0...0.45)
                    parameter("Curve exponent", value: route.calibration.exponent, range: 0.25...4)
                    if route.wrappedValue.destination.kind == .note || route.wrappedValue.destination.kind == .sustain {
                        parameter("Threshold", value: route.threshold, range: 0.05...1)
                        parameter("Hysteresis", value: route.hysteresis, range: 0...0.5)
                        Stepper("Note velocity \(route.wrappedValue.velocity)", value: route.velocity, in: 1...127)
                    }
                }.padding(4)
            }
        }
    }

    private func parameter(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 125, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 55)
        }
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
            draft = try InstrumentPatch.read(data)
            message = "Imported draft. Save changes or Start test to use it."
        } catch { message = error.localizedDescription }
    }
}
#endif
