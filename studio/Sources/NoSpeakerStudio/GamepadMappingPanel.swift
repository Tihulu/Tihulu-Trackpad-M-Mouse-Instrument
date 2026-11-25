#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct GamepadMappingPanel: View {
    @Binding var patch: InstrumentPatch
    @Binding var physical: Bool
    private enum Action: String, CaseIterable, Identifiable {
        case note = "Note", chord = "Chord", sustain = "Sustain", bend = "Pitch bend", cc = "MIDI CC", clear = "Unmapped"
        var id: String { rawValue }
    }
    @State private var slot: SensorSource = .gamepad1
    @State private var signal: SensorSignal = .padA
    @State private var action: Action = .note
    @State private var channel = 0
    @State private var number = 60
    @State private var chord = "60,64,67"
    @State private var velocity = 100
    @State private var message = ""
    private var analog: Bool { GamepadFrame.sticks.contains(signal) }
    private var allowed: [Action] { analog ? [.bend,.cc,.clear] : Action.allCases }
    private var selectedRoutes: [SensorMapping] {
        patch.routes.filter { $0.source == slot && $0.signal == signal }
    }
    private var destinations: [SensorDestination]? {
        switch action {
        case .note: return [.init(.note,channel:channel,number:number)]
        case .chord: return GamepadMappingEditor.parseNotes(chord)?.map { .init(.note,channel:channel,number:$0) }
        case .sustain: return [.init(.sustain,channel:channel)]
        case .bend: return [.init(.pitchBend,channel:channel)]
        case .cc: return [.init(.controlChange,channel:channel,number:number)]
        case .clear: return []
        }
    }
    private func summary(_ input: SensorSignal) -> String {
        let routes = patch.routes.filter { $0.source == slot && $0.signal == input }
        if routes.isEmpty { return "Unmapped" }
        return routes.map { r in
            let d = r.destination
            let name: String
            switch d.kind {
            case .note: name = (try? MusicTheory.noteName(midi:d.number)) ?? String(d.number)
            case .controlChange: name = "CC \(d.number)"
            case .pitchBend: name = "Bend"
            case .sustain: name = "Sustain"
            }
            return "\(name) · Ch \(d.channel+1)"
        }.joined(separator:", ")
    }
    var body: some View {
        GroupBox("Xbox / Gamepad · custom control map") {
            VStack(alignment:.leading,spacing:10) {
                Picker("Controller",selection:$slot) {
                    Text("Controller 1").tag(SensorSource.gamepad1)
                    Text("Controller 2").tag(SensorSource.gamepad2)
                }.pickerStyle(.segmented)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:6)],spacing:6) {
                    ForEach(GamepadFrame.signals,id:\.self) { input in
                        Button {
                            signal = input
                            if !allowed.contains(action) { action = .bend }
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(GamepadMappingEditor.label(input)).font(.headline)
                                Text(summary(input)).font(.caption).lineLimit(3)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(5)
                        }.buttonStyle(.bordered).tint(signal == input ? .accentColor : .secondary)
                    }
                }
                Divider()
                Text("Edit \(GamepadMappingEditor.label(signal))").font(.headline)
                Picker("Assignment",selection:$action) {
                    ForEach(allowed) { Text($0.rawValue).tag($0) }
                }
                .onChange(of:action) { value in
                    if value == .cc { number = 74 }
                    if value == .note { number = 60 }
                }
                if action != .clear {
                    Stepper("MIDI channel \(channel+1)",value:$channel,in:0...15)
                    if action == .note {
                        Stepper("Note \(number) · \((try? MusicTheory.noteName(midi:number)) ?? String(number))",value:$number,in:0...127)
                    } else if action == .chord {
                        TextField("MIDI notes (e.g. 60,64,67)",text:$chord)
                        HStack {
                            Button("C major") { chord = "60,64,67" }
                            Button("A minor") { chord = "57,60,64" }
                            Button("G7") { chord = "55,59,62,65" }
                        }
                    } else if action == .cc {
                        Stepper("CC \(number)",value:$number,in:0...119)
                        HStack {
                            Button("Modulation") { number = 1 }
                            Button("Expression") { number = 11 }
                            Button("Filter / Wah") { number = 74 }
                        }
                    }
                    if action == .note || action == .chord {
                        Stepper("Velocity \(velocity)",value:$velocity,in:1...127)
                    }
                }
                HStack {
                    Button(selectedRoutes.isEmpty ? "Assign control" : "Replace this control") {
                        guard let destinations else { return }
                        do {
                            patch = try GamepadMappingEditor.replace(in:patch,source:slot,signal:signal,destinations:destinations,velocity:velocity)
                            physical = true
                            message = "Mapping updated. Save or start explicitly."
                        } catch { message = "Invalid mapping or route capacity. Previous map preserved." }
                    }.buttonStyle(.borderedProminent)
                        .disabled(destinations == nil || !allowed.contains(action))
                    Text("\(patch.routes.count)/\(SensorRouter.maxMappings) routes").font(.caption)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text("One button can play up to 12 distinct notes. Sticks map to continuous controls. Advanced Routes supports additional simultaneous assignments and calibration. Other controller and device mappings are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
#endif
