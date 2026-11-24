#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Edits the same patch as the list editor. Applying compiles the graph to
/// routes; cancel leaves the original draft untouched.
struct VisualPatchbayView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var patch: InstrumentPatch
    @State private var graph = PatchGraph()
    @State private var original = PatchGraph()
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visual Patchbay").font(.title.bold())
            Text("Connect inputs to calibration processors, then to MIDI outputs. One node can feed multiple nodes in the next column. Choose connections from the menus; no audio or hardware is started here.")
                .foregroundStyle(.secondary)
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    inputColumn
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 14)
                    processorColumn
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 14)
                    outputColumn
                }
            }
            Text("Connections compile to the existing saved routes. Unused nodes are not stored; identical inputs and calibrations are grouped when reopening.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Reset changes") { graph = original; message = "" }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply connections") {
                    do {
                        patch = try graph.compile(name: patch.name)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 940, minHeight: 600)
            .onAppear {
                graph = PatchGraph(patch: patch)
                original = graph
            }
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Inputs", systemImage: "hand.point.up.left").font(.headline)
            ForEach($graph.inputs) { $node in
                let id = node.id
                GroupBox(inputLabel(id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Source", selection: $node.source) {
                            ForEach(SensorSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Signal", selection: $node.signal) {
                            ForEach(SensorSignal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Button("Remove", role: .destructive) { graph.removeInput(id) }.font(.caption)
                    }
                }
            }
            Button("Add input") { graph.inputs.append(.init()) }
                .disabled(graph.inputs.count >= PatchGraph.limit)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Calibration", systemImage: "slider.horizontal.3").font(.headline)
            ForEach($graph.processors) { $node in
                let id = node.id
                GroupBox(processorLabel(id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Input", selection: $node.inputID) {
                            Text("Not connected").tag(nil as String?)
                            ForEach(graph.inputs) { item in Text(inputLabel(item.id)).tag(Optional(item.id)) }
                        }
                        Toggle("Invert", isOn: $node.calibration.inverted)
                        parameter("Min", value: $node.calibration.minimum, range: 0...1)
                        parameter("Max", value: $node.calibration.maximum, range: 0...1)
                        parameter("Dead zone", value: $node.calibration.deadZone, range: 0...0.45)
                        parameter("Curve", value: $node.calibration.exponent, range: 0.25...4)
                        Button("Remove", role: .destructive) { graph.removeProcessor(id) }.font(.caption)
                    }
                }
            }
            Button("Add processor") { graph.processors.append(.init(inputID: graph.inputs.first?.id)) }
                .disabled(graph.processors.count >= PatchGraph.limit)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MIDI outputs", systemImage: "music.note").font(.headline)
            ForEach($graph.outputs) { $node in
                let id = node.id
                GroupBox("Output " + String((graph.outputs.firstIndex { $0.id == id } ?? 0) + 1)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Processor", selection: $node.processorID) {
                            Text("Not connected").tag(nil as String?)
                            ForEach(graph.processors) { item in Text(processorLabel(item.id)).tag(Optional(item.id)) }
                        }
                        Picker("Type", selection: Binding(get: { node.destination.kind }, set: { kind in
                            node.destination.kind = kind
                            node.response = nil
                            node.destination.number = kind == .note ? 60 : (kind == .controlChange ? 74 : 0)
                        })) {
                            ForEach(SensorDestinationKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Stepper("Channel \(node.destination.channel + 1)", value: $node.destination.channel, in: 0...15)
                        if node.destination.kind == .note || node.destination.kind == .controlChange {
                            Stepper("Number \(node.destination.number)", value: $node.destination.number,
                                    in: 0...(node.destination.kind == .note ? 127 : 119))
                        }
                        Stepper("Priority \(node.priority)", value: $node.priority, in: -100...100)
                        if node.destination.kind == .note || node.destination.kind == .sustain {
                            parameter("Gate", value: $node.threshold, range: 0.05...1)
                            parameter("Hysteresis", value: $node.hysteresis, range: 0...0.5)
                            Stepper("Velocity \(node.velocity)", value: $node.velocity, in: 1...127)
                        }
                        if ContinuousResponse.isContinuous(node.destination) {
                            ContinuousResponsePanel(response: $node.response, target: node.destination)
                        }
                        Button("Remove", role: .destructive) {
                            graph.outputs.removeAll { $0.id == id }
                        }.font(.caption)
                    }
                }
            }
            Button("Add output") { graph.outputs.append(.init(processorID: graph.processors.first?.id)) }
                .disabled(graph.outputs.count >= PatchGraph.limit)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputLabel(_ id: String) -> String {
        guard let i = graph.inputs.firstIndex(where: { $0.id == id }) else { return "Missing input" }
        let node = graph.inputs[i]
        return "\(i + 1) · \(node.source.rawValue).\(node.signal.rawValue)"
    }

    private func processorLabel(_ id: String) -> String {
        guard let i = graph.processors.firstIndex(where: { $0.id == id }) else { return "Missing processor" }
        return "P\(i + 1)"
    }

    private func parameter(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name + " " + String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit())
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(name)
        }
    }
}
#endif
