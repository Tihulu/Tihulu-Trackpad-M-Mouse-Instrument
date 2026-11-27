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
    private struct GenerationContext: Equatable, Sendable {
        let bank: ChordBank
        let slot: Int
        let style: NoteComposerStyle
        let complexity: Int
        let seed: Int
    }
    @State private var draft = ContextualComposerDraft<[Int?], GenerationContext>()
    @State private var feedback = ""

    private var generationContext: GenerationContext { .init(bank: studio.chordBank, slot: slot, style: style, complexity: complexity, seed: seed) }

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
                    Button("Preview generation") { generate() }.buttonStyle(.borderedProminent)
                    Button("Preview variation") { seed = seed == 9999 ? 1 : seed + 1; generate() }
                    Button("Undo replacement") {
                        if let previous=draft.undo(current:notes,context:generationContext){notes=previous;feedback="Replacement undone."}
                    }.disabled(!draft.canUndo(current:notes))
                    Spacer()
                }
                if let proposal=draft.proposal {
                    Text("Candidate: "+proposal.candidate.map{$0.map(String.init) ?? "Rest"}.joined(separator:" · ")).font(.caption.monospacedDigit())
                    HStack {
                        Button("Replace next pattern") {
                            if let next=draft.apply(current:notes,context:generationContext){notes=next;feedback="Next pattern replaced."}
                        }.disabled(!draft.canApply(current:notes,context:generationContext))
                        Button("Discard"){draft.discard();feedback=""}
                    }
                    if proposal.baseline != notes {Text("Pattern changed; generate a new preview.").font(.caption).foregroundStyle(.orange)}
                    else if proposal.candidate != notes && !draft.canApply(current:notes,context:generationContext) {Text("Composition settings changed; generate a new preview.").font(.caption).foregroundStyle(.orange)}
                }
                if !feedback.isEmpty {Text(feedback).font(.caption)}
                Text("Local rule-based composition, not a trained AI model. Uses nominal notes from the current chord bank; generated notes remain editable in the 16-step grid. No automatic playback. Tuned MPE export uses the current bank offsets. Use Play tuned MIDI with MIDI-only output for microtonal playback; normal Play Pattern remains nominal.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
        .onChange(of: notes) { _ in observeEditor() }
        .onChange(of: generationContext) { _ in observeEditor() }
    }

    private func observeEditor() {
        switch draft.observe(current: notes, context: generationContext) {
        case .grid: feedback = "Manual edit: previous previews and replacement history cleared."
        case .context: feedback = "Composition settings changed; generate a new preview."
        case .none: break
        }
    }

    private func generate() {
        let context = generationContext
        guard let result = PatternComposer.notes(bank: context.bank, slot: context.slot, style: context.style,
                                                  complexity: context.complexity, seed: context.seed) else {
            draft.discard();feedback="Cannot generate: selected chord or composition settings are unavailable.";return
        }
        draft.preview(current:notes,candidate:result,context:context)
        feedback=result==notes ? "Candidate matches the current pattern." : "Preview only; replace explicitly."
    }
}

struct DrumComposerPanel: View {
    @Binding var active: Set<String>
    @State private var style: DrumComposerStyle = .rock
    @State private var complexity = 55
    @State private var fills = true
    @State private var seed = 1
    private struct GenerationContext: Equatable, Sendable {
        let style: DrumComposerStyle
        let complexity: Int
        let fills: Bool
        let seed: Int
    }
    @State private var draft = ContextualComposerDraft<Set<String>, GenerationContext>()
    @State private var feedback = ""

    private var generationContext: GenerationContext { .init(style: style, complexity: complexity, fills: fills, seed: seed) }

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
                    Button("Preview generation") { generate() }.buttonStyle(.borderedProminent)
                    Button("Preview variation") { seed = seed == 9999 ? 1 : seed + 1; generate() }
                    Button("Undo replacement") {
                        if let previous=draft.undo(current:active,context:generationContext){active=previous;feedback="Replacement undone."}
                    }.disabled(!draft.canUndo(current:active))
                    Spacer()
                }
                if let proposal=draft.proposal {
                    Text("Candidate hits: "+proposal.candidate.sorted().joined(separator:" · ")).font(.caption.monospacedDigit())
                    HStack {
                        Button("Replace next pattern") {
                            if let next=draft.apply(current:active,context:generationContext){active=next;feedback="Next pattern replaced."}
                        }.disabled(!draft.canApply(current:active,context:generationContext))
                        Button("Discard"){draft.discard();feedback=""}
                    }
                    if proposal.baseline != active {Text("Pattern changed; generate a new preview.").font(.caption).foregroundStyle(.orange)}
                    else if proposal.candidate != active && !draft.canApply(current:active,context:generationContext) {Text("Composition settings changed; generate a new preview.").font(.caption).foregroundStyle(.orange)}
                }
                if !feedback.isEmpty {Text(feedback).font(.caption)}
                Text("Local groove rules with seeded variation. Generates editable hits, not rendered audio. No model download or automatic playback; the existing sequencer still controls the sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
        .onChange(of: active) { _ in observeEditor() }
        .onChange(of: generationContext) { _ in observeEditor() }
    }

    private func observeEditor() {
        switch draft.observe(current: active, context: generationContext) {
        case .grid: feedback = "Manual edit: previous previews and replacement history cleared."
        case .context: feedback = "Composition settings changed; generate a new preview."
        case .none: break
        }
    }

    private func generate() {
        let context = generationContext
        let result = PatternComposer.drums(style: context.style, complexity: context.complexity, fills: context.fills, seed: context.seed)
        guard !result.isEmpty else {
            draft.discard();feedback="Cannot generate: composition settings are unavailable.";return
        }
        draft.preview(current:active,candidate:result,context:context)
        feedback=result==active ? "Candidate matches the current pattern." : "Preview only; replace explicitly."
    }
}
#endif
