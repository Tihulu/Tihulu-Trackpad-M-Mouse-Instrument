#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct PerformanceLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var patch: InstrumentPatch
    @State private var widgets: [PerformanceWidget] = []
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance layout").font(.title.bold())
            Text("Choose controls for the existing mapped inputs. Reorder, rename or pair X and Y. This does not alter MIDI routing or enable hardware.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(widgets.enumerated()), id: \.element.id) { index, widget in
                        if widgets.indices.contains(index) {
                            GroupBox(widget.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        TextField("Label", text: $widgets[index].label)
                                        Picker("Style", selection: $widgets[index].kind) {
                                            Text("Slider").tag(PerformanceControlKind.slider)
                                            Text("Pedal").tag(PerformanceControlKind.pedal)
                                            Text("Tap pad").tag(PerformanceControlKind.pad)
                                            if widget.kind == .xy { Text("XY").tag(PerformanceControlKind.xy) }
                                        }
                                        Toggle("Wide", isOn: $widgets[index].wide)
                                    }
                                    HStack {
                                        Button("Up") { move(widget.id, by: -1) }.disabled(index == 0)
                                        Button("Down") { move(widget.id, by: 1) }.disabled(index == widgets.count - 1)
                                        if widget.kind == .xy {
                                            Button("Split XY") { split(widget.id) }
                                        } else if widget.signal == .x &&
                                            widgets.contains(where: { $0.source == widget.source && $0.signal == .y }) {
                                            Button("Pair X + Y") { pair(widget.id) }
                                        }
                                    }
                                }.padding(4)
                            }
                        }
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Reset layout") { widgets = PerformanceLayout.defaults(for: patch.routes).widgets }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply layout") {
                    let layout = PerformanceLayout(widgets: widgets)
                    guard layout.isValid else { message = "Invalid or duplicate control; labels must be at most 64 UTF-8 bytes."; return }
                    patch.performanceLayout = layout
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 680, minHeight: 480)
            .onAppear { widgets = (patch.performanceLayout ?? .init()).resolved(for: patch.routes) }
    }

    private func move(_ id: String, by delta: Int) {
        guard let index = widgets.firstIndex(where: { $0.id == id }),
              widgets.indices.contains(index + delta) else { return }
        widgets.swapAt(index, index + delta)
    }
    private func pair(_ id: String) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        let source = widgets[index].source
        guard let y = widgets.firstIndex(where: { $0.source == source && $0.signal == .y }) else { return }
        widgets[index].kind = .xy
        widgets[index].wide = true
        widgets.remove(at: y)
    }
    private func split(_ id: String) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        let source = widgets[index].source
        widgets[index].kind = .slider
        widgets.insert(.init(source: source, signal: .y), at: index + 1)
    }
}

struct PerformanceControlsView: View {
    @EnvironmentObject private var studio: StudioController
    let patch: InstrumentPatch
    @Binding var values: [PatchSimulation.Input: Double]

    private var widgets: [PerformanceWidget] {
        let available = Set(studio.patchInputs)
        return (patch.performanceLayout ?? .init()).resolved(for: patch.routes)
            .filter { $0.inputs.allSatisfy { available.contains($0) } }
    }
    // Preserve order and honor full-width controls without a nested ScrollView.
    private var rows: [[PerformanceWidget]] {
        var result: [[PerformanceWidget]] = []
        for widget in widgets {
            if !widget.wide, let last = result.last, last.count == 1, !last[0].wide {
                result[result.count - 1].append(widget)
            } else { result.append([widget]) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance controls").font(.headline)
            Text("On-screen inputs · live MIDI only if explicitly enabled. Tap pads send a 150 ms pulse; release removes ownership, not a synthetic zero.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { widget in
                        control(widget).frame(maxWidth: .infinity)
                    }
                }
            }
            HStack {
                ForEach(Array(Set(studio.patchInputs.map(\.source))).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                    Button("Disconnect " + source.rawValue) {
                        studio.disconnectPatchInput(source)
                        values = values.filter { $0.key.source != source }
                    }.controlSize(.small)
                }
            }
        }
    }

    private func value(_ input: PatchSimulation.Input) -> Binding<Double> {
        Binding(get: { values[input] ?? 0 }, set: { v in
            values[input] = v
            studio.sendPatchInput(input, value: v)
        })
    }

    private func control(_ widget: PerformanceWidget) -> some View {
        let input = widget.inputs[0]
        return GroupBox(widget.title) {
            VStack(alignment: .leading, spacing: 6) {
                switch widget.kind {
                case .slider:
                    Slider(value: value(input), in: 0...1).accessibilityLabel(widget.title)
                case .pedal:
                    ProgressView(value: values[input] ?? 0).tint(.accentColor)
                    Slider(value: value(input), in: 0...1).accessibilityLabel(widget.title + " position")
                case .pad:
                    Button("Tap · 150 ms") { studio.pulsePatchInput(input) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                case .xy:
                    if widget.inputs.count == 2 {
                        XYPerformancePad(x: value(input), y: value(widget.inputs[1]), label: widget.title)
                    }
                }
                if widget.kind != .pad && widget.kind != .xy {
                    Text("Input \(Int((values[input] ?? 0) * 100))%").font(.caption.monospacedDigit())
                }
                Button("Release") {
                    for key in widget.inputs {
                        studio.releasePatchInput(key)
                        values.removeValue(forKey: key)
                    }
                }.controlSize(.small)
            }.padding(4)
        }
    }
}

private struct XYPerformancePad: View {
    @Binding var x: Double
    @Binding var y: Double
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
                    Path { path in
                        path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
                        path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                    }.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                        .position(x: CGFloat(x) * proxy.size.width, y: CGFloat(1-y) * proxy.size.height)
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                        x = Double(min(1, max(0, gesture.location.x / proxy.size.width)))
                        y = Double(min(1, max(0, 1 - gesture.location.y / proxy.size.height)))
                    })
            }.frame(height: 110).accessibilityHidden(true)
            // Keyboard/VoiceOver alternative to the two-dimensional surface.
            HStack {
                Text("X").font(.caption)
                Slider(value: $x, in: 0...1).accessibilityLabel(label + " X")
                Text("Y").font(.caption)
                Slider(value: $y, in: 0...1).accessibilityLabel(label + " Y")
            }
        }
    }
}
#endif
