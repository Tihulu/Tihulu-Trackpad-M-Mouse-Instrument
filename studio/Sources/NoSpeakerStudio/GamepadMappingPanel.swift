#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct GamepadMappingPanel: View {
    @Binding var patch: InstrumentPatch
    @Binding var physical: Bool
    private enum Action: String, CaseIterable, Identifiable {
        case note = "Note", chord = "Chord", sustain = "Sustain", bend = "Pitch bend", cc = "MIDI CC", pedal = "Effect pedal / switch", clear = "Unmapped"
        var id: String { rawValue }
    }
    @State private var slot: SensorSource = .gamepad1
    @State private var signal: SensorSignal = .padA
    @State private var action: Action = .note
    @State private var channel = 0
    @State private var number = 74
    @State private var pedalMode = GamepadPedalMode.hold
    @State private var pedalCC = 80
    @State private var pedalSustain = false
    @State private var noteText = "C4"
    @State private var chord = "C4,E4,G4"
    @State private var confirmCopy = false
    @State private var copyTarget: SensorSource = .gamepad2
    @State private var copyBase: InstrumentPatch?
    @State private var pendingCopy: InstrumentPatch?
    @State private var presetChannel = 0
    @State private var confirmPreset = false
    @State private var presetBase: InstrumentPatch?
    @State private var pendingPreset: InstrumentPatch?
    @State private var remapCopyChannel = false
    @State private var copyChannel = 1
    @State private var complexSelection = false
    @State private var velocity = 100
    @State private var message = ""
    private var analog: Bool { GamepadFrame.sticks.contains(signal) }
    private var allowed: [Action] { analog ? [.bend,.cc,.clear] : Action.allCases }
    private var selectedRoutes: [SensorMapping] {
        patch.routes.filter { $0.source == slot && $0.signal == signal }
    }
    private var destinations: [SensorDestination]? {
        switch action {
        case .note:
            guard let notes = GamepadMappingEditor.parseNotes(noteText), notes.count == 1 else { return nil }
            return [.init(.note,channel:channel,number:notes[0])]
        case .chord: return GamepadMappingEditor.parseNotes(chord)?.map { .init(.note,channel:channel,number:$0) }
        case .sustain: return [.init(.sustain,channel:channel)]
        case .bend: return [.init(.pitchBend,channel:channel)]
        case .cc: return [.init(.controlChange,channel:channel,number:number)]
        case .pedal: return [pedalSustain ? .init(.sustain,channel:channel) : .init(.controlChange,channel:channel,number:pedalCC)]
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
            return "\(name) · Ch \(d.channel+1)" + (r.pedalMode.map { " · " + $0.rawValue } ?? "")
        }.joined(separator:", ")
    }
    private var copyTargets: [SensorSource] { GamepadFrame.orderedSources.filter { $0 != slot } }
    private func repairCopyTarget() {
        if copyTarget == slot, let first = copyTargets.first { copyTarget = first }
    }
    private func loadSelection() {
        let routes = selectedRoutes
        complexSelection = false
        guard let first = routes.first else {
            action = analog ? .bend : .note
            return
        }
        channel = first.destination.channel
        velocity = first.velocity
        let kind = first.destination.kind
        guard routes.allSatisfy({ $0.destination.channel == channel && $0.destination.kind == kind }),
              routes.count == 1 || (kind == .note && Set(routes.map(\.destination)).count == routes.count && routes.allSatisfy({ $0.velocity == velocity })) else {
            complexSelection = true
            action = analog ? .bend : .note
            return
        }
        if let mode = first.pedalMode {
            action = .pedal
            pedalMode = mode
            pedalSustain = kind == .sustain
            if !pedalSustain { pedalCC = first.destination.number }
            return
        }
        switch kind {
        case .note:
            if routes.count == 1 {
                action = .note
                noteText = (try? MusicTheory.noteName(midi:first.destination.number)) ?? String(first.destination.number)
            } else {
                action = .chord
                chord = routes.map { (try? MusicTheory.noteName(midi:$0.destination.number)) ?? String($0.destination.number) }.joined(separator:", ")
            }
        case .sustain: action = .sustain
        case .pitchBend: action = .bend
        case .controlChange: action = .cc; number = first.destination.number
        }
    }
    private func prepareCopy() {
        do {
            let occupied = patch.routes.contains { $0.source == copyTarget }
            let next = try GamepadMappingEditor.copy(in:patch,from:slot,to:copyTarget,
                    channel:remapCopyChannel ? copyChannel : nil,replaceExisting:occupied)
            if occupied {
                copyBase = patch
                pendingCopy = next
                confirmCopy = true
            } else {
                patch = next
                physical = true
                message = "Controller map copied. Original preserved."
            }
        } catch { message = "Copy refused: invalid routing or route capacity." }
    }

    private func preparePedalboard() {
        do {
            let occupied = patch.routes.contains { $0.source == slot }
            let next = try GamepadPedalboardPreset.install(in:patch,source:slot,channel:presetChannel,replaceExisting:occupied)
            if occupied {
                presetBase = patch
                pendingPreset = next
                confirmPreset = true
            } else {
                patch = next
                physical = true
                message = "Pedalboard added. Enable MIDI and learn the effect CCs in your DAW."
            }
        } catch { message = "Pedalboard refused: conflicting targets or route capacity. Existing map preserved." }
    }

    var body: some View {
        GroupBox("Xbox / Gamepad · custom control map") {
            VStack(alignment:.leading,spacing:10) {
                Picker("Controller",selection:$slot) {
                    ForEach(GamepadFrame.orderedSources,id:\.self) { source in
                        Text(GamepadFrame.slotLabel(source)).tag(source)
                    }
                }.pickerStyle(.segmented)
                HStack {
                    Toggle("New MIDI channel for copy",isOn:$remapCopyChannel)
                    if remapCopyChannel { Stepper("Ch \(copyChannel+1)",value:$copyChannel,in:0...15) }
                    Picker("Copy to",selection:$copyTarget) {
                        ForEach(copyTargets,id:\.self) { source in
                            Text(GamepadFrame.slotLabel(source)).tag(source)
                        }
                    }
                    Button("Copy map…") { prepareCopy() }
                        .disabled(copyTarget == slot || !patch.routes.contains(where:{ $0.source == slot }))
                }
                HStack {
                    Stepper("Pedalboard Ch \(presetChannel+1)",value:$presetChannel,in:0...15)
                    Button("Load effect pedalboard…") { preparePedalboard() }
                }
                .confirmationDialog("Replace selected controller with a pedalboard?",isPresented:$confirmPreset,titleVisibility:.visible) {
                    Button("Replace selected controller",role:.destructive) {
                        if let base = presetBase, let next = pendingPreset, patch == base {
                            patch = next
                            physical = true
                            message = "Pedalboard loaded. Other device routes preserved."
                        } else { message = "Draft changed. Review and try again." }
                        presetBase = nil
                        pendingPreset = nil
                    }
                    Button("Cancel",role:.cancel) { presetBase = nil; pendingPreset = nil }
                } message: {
                    Text("Only the selected controller's old map will be replaced. Other devices and the saved patch remain unchanged until you save.")
                }
                Text("A/B/X/Y and RB: Toggle · LB: Hold · LT: Wah CC74 · RT: Sustain · sticks: Bend / Expression. Learn CC80–85 in your DAW; this preset does not select plug-ins automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:6)],spacing:6) {
                    ForEach(GamepadFrame.signals,id:\.self) { input in
                        Button {
                            signal = input
                            loadSelection()
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
                if complexSelection {
                    Text("This control has mixed or individually voiced routes. Use Advanced Routes to edit them separately, or explicitly replace the entire control below.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if action != .clear {
                    Stepper("MIDI channel \(channel+1)",value:$channel,in:0...15)
                    if action == .note {
                        TextField("Note name or MIDI number",text:$noteText)
                        if let note = destinations?.first?.number {
                            Text("\((try? MusicTheory.noteName(midi:note)) ?? String(note)) · MIDI \(note)").font(.caption)
                        }
                    } else if action == .chord {
                        TextField("Notes (C4,E4,G4 or 60,64,67)",text:$chord)
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
                    if action == .pedal {
                        Picker("Behavior",selection:$pedalMode) {
                            ForEach(GamepadPedalMode.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Toggle("Sustain (CC64)",isOn:$pedalSustain)
                        if !pedalSustain {
                            Stepper("Effect CC \(pedalCC)",value:$pedalCC,in:0...119)
                            HStack {
                                Button("Drive / switch 1 (80)") { pedalCC = 80 }
                                Button("Switch 2 (81)") { pedalCC = 81 }
                                Button("Switch 3 (82)") { pedalCC = 82 }
                            }
                        }
                        Text(pedalMode == .hold ? "Press = 127, release = 0." : "First press = 127, next press = 0. Release rearms the switch. Stop or disconnect clears its ownership.")
                            .font(.caption)
                        Text("Assign the CC to a plug-in parameter in your DAW. Names are examples, not universal effect numbers. Switches use binary values and replace this control’s custom calibration/curve; use Advanced Routes for analog effects.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if action == .note || action == .chord {
                        Stepper("Velocity \(velocity)",value:$velocity,in:1...127)
                    }
                }
                HStack {
                    Button(selectedRoutes.isEmpty ? "Assign control" : "Replace this control") {
                        guard let destinations else { return }
                        do {
                            patch = try GamepadMappingEditor.replace(in:patch,source:slot,signal:signal,destinations:destinations,velocity:velocity,pedalMode:action == .pedal ? pedalMode : nil)
                            physical = true
                            loadSelection()
                            message = "Mapping updated. Save or start explicitly."
                        } catch { message = "Invalid mapping, reserved CC, mixed analog/switch target or route capacity. Previous map preserved." }
                    }.buttonStyle(.borderedProminent)
                        .disabled(destinations == nil || !allowed.contains(action))
                    Text("\(patch.routes.count)/\(SensorRouter.maxMappings) routes").font(.caption)
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text("One button can play up to 12 distinct notes. Sticks map to continuous controls. Advanced Routes supports additional simultaneous assignments and calibration. Other controller and device mappings are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .onAppear { loadSelection() }
        .onChange(of:slot) { _ in repairCopyTarget(); loadSelection() }
        .onChange(of:patch) { _ in loadSelection() }
        .confirmationDialog("Replace the other controller map?",isPresented:$confirmCopy,titleVisibility:.visible) {
            Button("Replace destination map",role:.destructive) {
                if let base = copyBase, let next = pendingCopy, patch == base {
                    patch = next
                    physical = true
                    message = "Controller map copied. Original preserved."
                } else { message = "Draft changed. Review and try again." }
                copyBase = nil; pendingCopy = nil
            }
            Button("Cancel",role:.cancel) { copyBase = nil; pendingCopy = nil }
        } message: {
            Text("Only the destination controller's mappings will be replaced. The original and other devices stay unchanged.")
        }
    }
}
#endif
