#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore

struct InstrumentBuilderView: View {
    @EnvironmentObject private var studio: StudioController
    @State private var draft = InstrumentPatch()
    @State private var sendMIDI = false
    @State private var physical = false
    @State private var values: [PatchSimulation.Input: Double] = [:]
    @State private var message = ""
    @State private var showPatchbay = false

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
                        }
                    }.padding(8).disabled(studio.patchRunning)
                }
                ExpressivePresetPanel(patch: $draft).disabled(studio.patchRunning)
                GroupBox("Routes · \(draft.routes.count)/64") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($draft.routes) { $route in
                            routeEditor($route)
                            Button("Remove route", role: .destructive) {
                                draft.routes.removeAll { $0.id == route.id }
                            }.font(.caption)
                            Divider()
                        }
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
                            Text("Physical surfaces (experimental)").tag(true)
                        }.pickerStyle(.segmented).disabled(studio.patchRunning)
                        Toggle("Send controls to dedicated MIDI output", isOn: $sendMIDI)
                            .disabled(studio.patchRunning)
                        if physical && !PhysicalPatchRuntime.supports(draft) {
                            Text("Physical mode requires only Trackpad / external touch-surface routes with X, Y, contact or contact size. Other sources remain simulation-only.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Start test") {
                                studio.updateInstrumentPatch(draft)
                                values = [:]
                                studio.startInstrumentPatch(sendMIDI: sendMIDI, physical: physical)
                            }.buttonStyle(.borderedProminent)
                                .disabled(studio.patchRunning || !draft.isValid || draft.routes.isEmpty || (physical && !PhysicalPatchRuntime.supports(draft)))
                            Button("Stop / Release All") { studio.stopInstrumentPatch() }
                            Spacer()
                            Text(studio.patchStatus).font(.caption)
                        }
                        ForEach(studio.patchInputs) { input in
                            HStack {
                                Text(input.id).frame(width: 160, alignment: .leading)
                                Slider(value: Binding(get: { values[input] ?? 0 }, set: { value in
                                    values[input] = value
                                    studio.sendPatchInput(input, value: value)
                                }), in: 0...1)
                                Button("Disconnect source") { studio.disconnectPatchInput(input.source) }
                            }
                        }
                        if physical {
                            Text("Primary contact per surface; contact size is not measured pressure. The private macOS driver groups compatible external touch surfaces under Magic Mouse; device identity is not verified here. The shared monitor supports independent Touch Instrument and MIDI Helper sessions; route the dedicated MIDI source separately in the DAW. Lift or loss of input releases owned controls. No automatic pointer capture.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Use TIHULU Instrument Builder as a dedicated DAW input if MIDI is enabled. Connect a separate instrument/channel. Stop or Panic releases owned controls. Physical sessions continue across pages; simulation ends when leaving. No network access.")
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
        .onAppear {
            draft = studio.instrumentPatch
            if studio.patchRunning { physical = studio.patchPhysical }
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
