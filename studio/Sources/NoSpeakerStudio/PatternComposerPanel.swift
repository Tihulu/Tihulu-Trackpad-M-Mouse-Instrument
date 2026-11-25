#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct NoteComposerPanel: View {
    @EnvironmentObject private var studio: StudioController
    @Binding var notes: [Int?]
    @State private var style: NoteComposerStyle = .melody
    @State private var slot = 0
    @State private var complexity = 55
    @State private var seed = 1
    @State private var previous: [Int?]?

    var body: some View {
        GroupBox("Smart Compose — notes") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Style", selection: $style) {
                        ForEach(NoteComposerStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Chord", selection: $slot) {
                        ForEach(0..<ChordBank.padCount, id: \.self) { index in
                            Text("\(index + 1) · " + (studio.chordBank.pad(at: index)?.name ?? "Unavailable")).tag(index)
                        }
                    }
                }
                HStack {
                    Text("Complexity")
                    Slider(value: Binding(get: { Double(complexity) }, set: { complexity = Int($0.rounded()) }), in: 0...100)
                    Text("\(complexity)%").monospacedDigit()
                    Stepper("Seed \(seed)", value: $seed, in: 1...9999)
                }
                HStack {
                    Button("Generate") { generate() }.buttonStyle(.borderedProminent)
                    Button("Variation") { seed = seed == 9999 ? 1 : seed + 1; generate() }
                    Button("Undo generation") {
                        if let previous { notes = previous; self.previous = nil }
                    }.disabled(previous == nil)
                    Spacer()
                }
                Text("Local rule-based composition, not a trained AI model. Uses nominal notes from the current chord bank; generated notes remain editable in the 16-step grid. No automatic playback. Tuned MPE export uses the current bank offsets. Use Play tuned MIDI with MIDI-only output for microtonal playback; normal Play Pattern remains nominal.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private func generate() {
        guard let result = PatternComposer.notes(bank: studio.chordBank, slot: slot, style: style,
                                                  complexity: complexity, seed: seed) else { return }
        previous = notes
        notes = result
    }
}

struct DrumComposerPanel: View {
    @Binding var active: Set<String>
    @State private var style: DrumComposerStyle = .rock
    @State private var complexity = 55
    @State private var fills = true
    @State private var seed = 1
    @State private var previous: Set<String>?

    var body: some View {
        GroupBox("Smart Compose — drums") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Style", selection: $style) {
                        ForEach(DrumComposerStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("End fill", isOn: $fills)
                    Stepper("Seed \(seed)", value: $seed, in: 1...9999)
                }
                HStack {
                    Text("Complexity")
                    Slider(value: Binding(get: { Double(complexity) }, set: { complexity = Int($0.rounded()) }), in: 0...100)
                    Text("\(complexity)%").monospacedDigit()
                }
                HStack {
                    Button("Generate") { generate() }.buttonStyle(.borderedProminent)
                    Button("Variation") { seed = seed == 9999 ? 1 : seed + 1; generate() }
                    Button("Undo generation") {
                        if let previous { active = previous; self.previous = nil }
                    }.disabled(previous == nil)
                    Spacer()
                }
                Text("Local groove rules with seeded variation. Generates editable hits, not rendered audio. No model download or automatic playback; the existing sequencer still controls the sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private func generate() {
        previous = active
        active = PatternComposer.drums(style: style, complexity: complexity, fills: fills, seed: seed)
    }
}
#endif
