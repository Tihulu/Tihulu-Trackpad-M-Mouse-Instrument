#if os(macOS)
import Foundation
import SwiftUI
import NoSpeakerCore

struct SharedNoteOutputSetting: View {
    @EnvironmentObject private var studio: StudioController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Shared Chord Pads + Touch Bar (experimental)", isOn: Binding(
                get: { studio.sharedNoteOutputEnabled },
                set: { studio.setSharedNoteOutputEnabled($0) }
            )).disabled(studio.liveNoteOwnsHaptics)
            Text("Off by default. Enable before arming either Trackpad/Both output. Both share a six-tone budget. Use the chord strip beside the Touch Bar controls; other haptic engines remain exclusive. Panic resets this setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ChordPadPanel: View {
    @EnvironmentObject private var studio: StudioController
    let compact: Bool
    @State private var editSlot: Int?
    @State private var customName = ""
    @State private var customNotes = ""
    @State private var editError = ""

    private func binding<T>(_ key: WritableKeyPath<ChordBank, T>) -> Binding<T> {
        Binding(get: { studio.chordBank[keyPath: key] }, set: { value in
            var bank = studio.chordBank
            bank[keyPath: key] = value
            studio.updateChordBank(bank)
        })
    }

    var body: some View {
        if compact {
            content
        } else {
            ScrollView { content.padding(24) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack {
                Text("Chord Pads").font(compact ? .headline : .largeTitle.bold())
                Spacer()
                Text(studio.chordStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if studio.progressionRunning {
                    Button("Stop progression") { studio.stopChordProgression() }
                }
                Button(studio.chordArmed ? "Disarm" : "Arm Output") {
                    if studio.chordArmed { studio.disarmChordPads() }
                    else { studio.armChordPads() }
                }.buttonStyle(.borderedProminent)
                Button("Release All") { studio.releaseChordPads() }
            }
            if !compact {
                Text("Choose a key, play or assign voicings, and select MIDI, Trackpad or Both. For MIDI use the dedicated TIHULU Chord Pads DAW input and a separate track/channel.")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Destination", selection: Binding(
                            get: { studio.chordBank.effectiveOutput },
                            set: { output in
                                var bank = studio.chordBank
                                bank.output = output
                                studio.updateChordBank(bank)
                            }
                        )) {
                            ForEach(MusicalOutput.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).disabled(studio.chordArmed)
                        SharedNoteOutputSetting()
                        Text("Trackpad uses up to six tones with octave folding. MIDI retains the complete voicing. Other legacy haptic performances require disarming first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Harmony") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Root", selection: binding(\.root)) {
                                ForEach(36...71, id: \.self) { note in
                                    Text((try? MusicTheory.noteName(midi: note)) ?? String(note)).tag(note)
                                }
                            }
                            Picker("Scale", selection: binding(\.scale)) {
                                ForEach(ChordScale.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                        HStack {
                            Picker("Voicing", selection: binding(\.stack)) {
                                ForEach(ChordStack.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Stepper("Inversion \(studio.chordBank.inversion)", value: binding(\.inversion), in: 0...2)
                        }
                        HStack {
                            Stepper("MIDI channel \(studio.chordBank.channel)", value: binding(\.channel), in: 1...16)
                            Stepper("Velocity \(studio.chordBank.velocity)", value: binding(\.velocity), in: 1...127)
                        }
                        HStack {
                            Toggle("Latch / toggle chords", isOn: binding(\.latch))
                            if !studio.chordBank.latch {
                                Stepper("Gate \(studio.chordBank.gateMS) ms", value: binding(\.gateMS), in: 100...2000, step: 100)
                            }
                        }
                        Text("Makam-inspired options are equal-tempered pitch collections, not authentic makam intonation or melodic seyir. Scale stacks are creative harmony, not traditional makam chord rules.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(studio.chordArmed)
                }
            } else {
                Text(compactSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            padGrid
            if !compact {
                ChordProgressionPanel()
                Text("Custom chords stay fixed when you change the scale. Disarm before editing. Settings are saved locally; no notes or output resume on launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { editSlot != nil }, set: { if !$0 { editSlot = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Assign custom chord").font(.title2.bold())
                TextField("Chord name", text: $customName)
                TextField("Notes or MIDI numbers", text: $customNotes)
                Text("Enter 1–8 distinct notes, separated by commas or spaces. Examples: C4 E4 G4 B4 or 60, 64, 67, 71.")
                    .font(.caption).foregroundStyle(.secondary)
                if !editError.isEmpty { Text(editError).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { editSlot = nil }
                    Button("Assign") { saveCustom() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 420)
        }
        .onDisappear { studio.releaseManualChordPadsOnDisappear() }
    }

    private var compactSummary: String {
        let bank = studio.chordBank
        return [bank.scale.rawValue, bank.effectiveOutput.rawValue,
                bank.latch ? "Latch" : "Timed gate", "Ch " + String(bank.channel)].joined(separator: " · ")
    }

    private var padGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: compact ? 8 : 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<ChordBank.padCount, id: \.self) { slot in
                if let pad = studio.chordBank.pad(at: slot) {
                    padCell(slot: slot, pad: pad)
                }
            }
        }
    }

    private func padCell(slot: Int, pad: ChordPad) -> some View {
        let isCustom = studio.chordBank.overrides[slot] != nil
        let label = (isCustom ? "Custom " : "Pad ") + String(slot + 1)
        let active = studio.chordActiveSlots.contains(slot)
        let accessibility = "Chord pad " + String(slot + 1) + ", " + pad.name + ", " + pad.noteNames
        return VStack(spacing: 4) {
            Button { studio.triggerChordPad(slot) } label: {
                VStack(spacing: 4) {
                    Text(pad.name).font(.headline).lineLimit(1)
                    if !compact { Text(pad.noteNames).font(.caption).lineLimit(2) }
                    Text(label).font(.caption2)
                }.frame(maxWidth: .infinity, minHeight: compact ? 38 : 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(active ? Color.green : Color.accentColor)
            .disabled(!studio.chordArmed)
            .accessibilityLabel(accessibility)
            if !compact {
                padEditorButtons(slot: slot, pad: pad, isCustom: isCustom)
            }
        }
    }

    private func padEditorButtons(slot: Int, pad: ChordPad, isCustom: Bool) -> some View {
        HStack {
            Button("Assign") {
                editSlot = slot
                customName = pad.name
                customNotes = pad.notes.map(String.init).joined(separator: ", ")
                editError = ""
            }
            if isCustom {
                Button("Reset") {
                    var bank = studio.chordBank
                    bank.overrides.removeValue(forKey: slot)
                    studio.updateChordBank(bank)
                }
            }
        }.disabled(studio.chordArmed)
    }

    private func saveCustom() {
        guard let slot = editSlot, !studio.chordArmed else { return }
        guard let notes = ChordPad.parseNotes(customNotes) else {
            editError = "Enter 1–8 distinct valid notes or MIDI numbers."
            return
        }
        let pad = ChordPad(name: customName.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes)
        guard pad.isValid else {
            editError = "Enter a valid chord name."
            return
        }
        var bank = studio.chordBank
        bank.overrides[slot] = pad
        studio.updateChordBank(bank)
        editSlot = nil
    }
}
#endif
