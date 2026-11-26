#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

struct PerformanceLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var patch: InstrumentPatch
    @State private var widgets: [PerformanceWidget] = []
    @State private var preserveDormant = true
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance layout").font(.title.bold())
            Text("Choose controls for the existing mapped inputs. Reorder, rename or pair X and Y. This does not alter MIDI routing or enable hardware. Unmapped saved controls are retained unless you reset the layout; editing a temporary fallback replaces its original style.")
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
                                            Text("Knob").tag(PerformanceControlKind.knob)
                                            Text("Ribbon").tag(PerformanceControlKind.ribbon)
                                            if widget.keyPressValue(for: patch.routes) != nil {
                                                Text("Note key").tag(PerformanceControlKind.key)
                                            }
                                            if widget.kind == .xy { Text("XY").tag(PerformanceControlKind.xy) }
                                        }.disabled(widget.kind == .xy)
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
                Button("Reset layout") { widgets = PerformanceLayout.defaults(for: patch.routes).widgets; preserveDormant = false; message = "Reset will replace all saved controls, including dormant labels. Cancel to keep the original layout." }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply layout") {
                    do {
                        patch.performanceLayout = try (patch.performanceLayout ?? .init()).applyingVisibleEdits(widgets,for:patch.routes,preserveDormant:preserveDormant)
                        dismiss()
                    } catch {
                        message = "Invalid, duplicate or over-capacity layout. Labels must be at most 64 UTF-8 bytes. Reset explicitly if dormant controls no longer need to be saved."
                    }
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

    private var resolvedWidgets:[PerformanceWidget] {
        (patch.performanceLayout ?? .init()).resolved(for:patch.routes)
    }
    private var widgets: [PerformanceWidget] {
        let available = Set(studio.patchInputs)
        return resolvedWidgets.filter { $0.inputs.allSatisfy { available.contains($0) } }
    }
    private var unavailableWidgets:[PerformanceWidget] {
        let available=Set(studio.patchInputs)
        return resolvedWidgets.filter{ !$0.inputs.allSatisfy{available.contains($0)} }
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
            Text("On-screen inputs · live MIDI only if explicitly enabled. Knobs and XY pads hold position until Release; ribbons and note keys release on lift. Tap pads send a 150 ms pulse. Release removes ownership, not a synthetic zero.")
                .font(.caption).foregroundStyle(.secondary)
            if widgets.isEmpty {Text("No on-screen inputs available for the current session.").font(.caption).foregroundStyle(.secondary)}
            ForEach(unavailableWidgets) { widget in
                Text("\(widget.title) · unavailable: assigned input is not active in this on-screen session.").font(.caption).foregroundStyle(.secondary)
            }
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

    private func release(_ input: PatchSimulation.Input) {
        studio.releasePatchInput(input)
        values.removeValue(forKey: input)
    }

    private func noteLabel(_ widget: PerformanceWidget) -> String {
        let notes = Set(patch.routes.filter { $0.source == widget.source && $0.signal == widget.signal && $0.destination.kind == .note }
            .map(\.destination.number)).sorted()
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return notes.map { names[$0 % 12] + String($0 / 12 - 1) }.joined(separator: " + ")
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
                    let press = widget.pulseValue(for: patch.routes)
                    Button("Tap · 150 ms") {
                        if let press { studio.pulsePatchInput(input, value: press) }
                    }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(press == nil)
                    if press == nil {
                        Text("No common gate endpoint. Adjust calibration or choose a slider.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                case .knob:
                    RotaryPerformanceControl(value: value(input), label: widget.title)
                case .ribbon:
                    RibbonPerformanceControl(value: value(input), label: widget.title,
                        release: { release(input) })
                case .key:
                    if let press = widget.keyPressValue(for: patch.routes) {
                        HeldNoteControl(label: noteLabel(widget),
                            press: { studio.sendPatchInput(input, value: press) },
                            release: { release(input) },
                            pulse: { studio.pulsePatchInput(input, value: press) })
                    } else {
                        Text("Key unavailable: no compatible press endpoint. Adjust its mapping or choose another control.").font(.caption).foregroundStyle(.orange)
                    }
                case .xy:
                    if widget.inputs.count == 2 {
                        XYPerformancePad(x: value(input), y: value(widget.inputs[1]), label: widget.title)
                        Text("Holds both axes on lift. Release relinquishes both input owners.").font(.caption).foregroundStyle(.secondary)
                        ForEach(widget.inputs,id:\.self) { axis in
                            let targets=patch.routes.filter{$0.source==axis.source && $0.signal==axis.signal}.map{BuilderRouteTools.summary($0)}
                            Text(axis.signal.rawValue.uppercased()+": "+targets.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("XY unavailable: two assigned axes are required.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if widget.kind != .pad && widget.kind != .xy && widget.kind != .key {
                    Text("Input \(Int((values[input] ?? 0) * 100))%").font(.caption.monospacedDigit())
                }
                Button("Release") {
                    for key in widget.inputs { release(key) }
                }.controlSize(.small)
            }.padding(4)
        }
    }
}

private struct RotaryPerformanceControl: View {
    @Binding var value: Double
    let label: String
    @State private var origin: Double?
    @GestureState private var dragging = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.13))
                Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                Capsule().fill(Color.accentColor).frame(width: 4, height: 19)
                    .offset(y: -19).rotationEffect(.degrees(-135 + value * 270))
                Text(String(Int((value * 100).rounded()))).font(.caption.monospacedDigit())
            }.frame(width: 72, height: 72).contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        if origin == nil { origin = value }
                        value = min(1, max(0, (origin ?? value) - Double(gesture.translation.height) / 150))
                    }.onEnded { _ in origin = nil })
                .onChange(of: dragging) { active in if !active { origin = nil } }
                .accessibilityHidden(true)
            Slider(value: $value, in: 0...1).accessibilityLabel(label)
            Text("Drag up/down · holds position").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct RibbonPerformanceControl: View {
    @Binding var value: Double
    let label: String
    let release: () -> Void
    @GestureState private var touching = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.13))
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    Capsule().fill(Color.accentColor).frame(width: 8, height: 34)
                        .position(x: max(4, min(proxy.size.width - 4, CGFloat(value) * proxy.size.width)),
                                  y: proxy.size.height / 2)
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($touching) { _, state, _ in state = true }
                        .onChanged { gesture in
                            guard proxy.size.width > 0 else { return }
                            value = Double(min(1, max(0, gesture.location.x / proxy.size.width)))
                        }.onEnded { _ in release() })
                    .onChange(of: touching) { active in if !active { release() } }
            }.frame(height: 42).accessibilityHidden(true)
            Slider(value: $value, in: 0...1, onEditingChanged: { editing in if !editing { release() } })
                .accessibilityLabel(label)
            Text("Slide · returns on release").font(.caption2).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in release() }
        .onDisappear { release() }
    }
}

private struct HeldNoteControl: View {
    let label: String
    let press: () -> Void
    let release: () -> Void
    let pulse: () -> Void
    @GestureState private var touching = false
    @State private var held = false

    var body: some View {
        VStack(spacing: 5) {
            Text(label.isEmpty ? "Note" : label)
                .font(.headline).padding(8).frame(maxWidth: .infinity, minHeight: 70)
                .background(touching ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.45)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { _ in
                        if !held { held = true; press() }
                    }.onEnded { _ in end() })
                .onChange(of: touching) { active in if !active { end() } }
                .accessibilityHidden(true)
            Button("Tap " + label) { end(); pulse() }.controlSize(.small)
                .help("Keyboard-accessible 150 ms note pulse")
            Text("Hold to play · lift to release").font(.caption2).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in release(); held = false }
        .onDisappear { release(); held = false }
    }

    private func end() {
        if held { held = false; release() }
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
