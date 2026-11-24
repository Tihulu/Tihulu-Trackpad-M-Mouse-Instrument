#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct ChordProgressionPanel: View {
    @EnvironmentObject private var studio: StudioController

    private func setting<T>(_ key: WritableKeyPath<ChordProgression, T>) -> Binding<T> {
        Binding(get: { studio.chordProgression[keyPath: key] }, set: { value in
            var next = studio.chordProgression
            next[keyPath: key] = value
            studio.updateChordProgression(next)
        })
    }

    private func slotBinding(_ index: Int) -> Binding<Int> {
        Binding(get: { studio.chordProgression.slots.indices.contains(index) ? (studio.chordProgression.slots[index] ?? -1) : -1 }, set: { slot in
            var next = studio.chordProgression
            guard next.slots.indices.contains(index) else { return }
            next.slots[index] = slot < 0 ? nil : slot
            studio.updateChordProgression(next)
        })
    }

    private func resize(_ delta: Int) {
        var next = studio.chordProgression
        let count = next.slots.count + delta
        guard (1...16).contains(count) else { return }
        if delta > 0 { next.slots.append(nil) }
        else { next.slots.removeLast() }
        studio.updateChordProgression(next)
    }

    var body: some View {
        GroupBox("Chord progression") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(studio.progressionRunning ? "Stop" : "Play progression") {
                        if studio.progressionRunning { studio.stopChordProgression() }
                        else { studio.startChordProgression() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!studio.chordArmed)
                    MIDIClipExportButton(filename: "TIHULU Chords",
                                         title: studio.chordBank.customScale?.isMicrotonal == true ? "Export MIDI (12-TET)" : "Export MIDI") {
                        try MIDIClip.progression(studio.chordProgression, bank: studio.chordBank, bpm: studio.bpm)
                    }.disabled(studio.progressionRunning)
                    Text(studio.progressionRunning ? (studio.progressionSingleSlot == nil ? "Playing" : "Pad arpeggio") : "Stopped")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f BPM · %@", studio.bpm, studio.chordBank.effectiveOutput.rawValue))
                        .font(.caption)
                }
                settings
                    .disabled(studio.progressionRunning)
                ArpeggioPanel().disabled(studio.progressionRunning)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(studio.chordProgression.slots.indices, id: \.self) { index in
                        stepCell(index)
                    }
                }.disabled(studio.progressionRunning)
                Text("MIDI export writes one cycle of nominal notes, not microtonal MPE bends. Import the file into your DAW and choose an instrument.").font(.caption).foregroundStyle(.secondary)
                Text("Uses the current bank, including custom chords and its selected output. Arm first. Tempo is captured when Play starts. A manual pad press takes over; Release All, Panic, disarm or loss of app focus stops the progression. Changing pages does not stop it.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Beats per step", selection: setting(\.beatsPerStep)) {
                    ForEach([1,2,4], id: \.self) { Text(String($0)).tag($0) }
                }
                Stepper("Gate \(studio.chordProgression.gatePercent)%", value: setting(\.gatePercent),
                        in: 10...100, step: 10)
                Toggle("Loop", isOn: setting(\.loop))
            }
            HStack {
                Text("\(studio.chordProgression.slots.count) steps")
                Button("Add rest") { resize(1) }.disabled(studio.chordProgression.slots.count >= 16)
                Button("Remove last") { resize(-1) }.disabled(studio.chordProgression.slots.count <= 1)
                Spacer()
                Button("Reset progression") { studio.updateChordProgression(ChordProgression()) }
            }
        }
    }

    private func stepCell(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(index + 1)" + (studio.progressionSingleSlot == nil && studio.progressionStep == index ? " · Playing" : ""))
                .font(.caption.bold())
            Picker("Chord", selection: slotBinding(index)) {
                Text("Rest").tag(-1)
                ForEach(0..<ChordBank.padCount, id: \.self) { slot in
                    Text("\(slot + 1) · " + (studio.chordBank.pad(at: slot)?.name ?? "Unavailable"))
                        .tag(slot)
                }
            }.labelsHidden()
        }.padding(6)
        .background(studio.progressionSingleSlot == nil && studio.progressionStep == index ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
