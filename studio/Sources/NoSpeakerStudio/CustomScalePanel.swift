#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct CustomScalePanel: View {
    @EnvironmentObject private var studio: StudioController
    @State private var draft = CustomScale()
    @State private var editing = false
    @State private var centsText = ""
    @State private var centsError = ""

    var body: some View {
        GroupBox("Scale & tuning editor") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(studio.chordBank.scaleName).font(.headline)
                    Spacer()
                    Button("Edit custom scale") {
                        var next = CustomScale()
                        next.intervals = studio.chordBank.scale.intervals
                        draft = studio.chordBank.customScale ?? next
                        centsText = draft.degreeCents.map(String.init).joined(separator:", ")
                        centsError = ""
                        editing = true
                    }
                    if studio.chordBank.customScale != nil {
                        Button("Use built-in scale") {
                            var bank = studio.chordBank
                            bank.customScale = nil
                            studio.updateChordBank(bank)
                        }
                    }
                }
                if let scale = studio.chordBank.customScale {
                    Text(scale.intervals.map { String($0 * 100 + (scale.centOffsets[$0] ?? 0)) + "¢" }.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                    if scale.isMicrotonal {
                        Text(studio.chordBank.microtonalMPE == true
                             ? "Chord MIDI: dedicated MPE tuning. Touch Instrument supports tuned MPE, haptic output or explicit 12-TET approximation."
                             : (scale.allowEqualTemperedMIDI
                                ? "Trackpad: tuned frequencies. MIDI: explicitly allowed 12-TET approximation."
                                : "Trackpad: tuned frequencies. MIDI/Both require dedicated MPE or explicit approximation."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                PhysicalKeyboardScalePreview(scale:studio.chordBank.customScale ?? builtInScale)
                Text("Root-relative octave scale, used by generated chords, progressions and arpeggios. Custom chord MIDI notes stay fixed; tuning applies by pitch class. Copy the scale from Touch Instrument to use fretted tuning. External chord tuning requires a compatible MPE receiver.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom scale & intonation").font(.title2.bold())
                TextField("Scale name", text: $draft.name)
                Text("Select at least two degrees including the root. Adjust each selected degree by ±49 cents from its nominal semitone.")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("Import exact degree cents") {
                    VStack(alignment:.leading,spacing:6) {
                        TextField("0, 200, 375, 500, 700, 900, 1100",text:$centsText)
                        HStack {
                            Button("Use cents list") {
                                guard let next = CustomScale.fromDegreeCents(centsText,name:draft.name,
                                    allowEqualTemperedMIDI:draft.allowEqualTemperedMIDI) else {
                                    centsError = "Not representable losslessly. Use distinct semitone anchors, ±49 cents; for dense or 50-cent steps use custom string frets."
                                    return
                                }
                                draft = next; centsError = ""
                            }
                            Button("Copy current degrees into field") {
                                centsText = draft.degreeCents.map(String.init).joined(separator:", ")
                                centsError = ""
                            }
                        }
                        if !centsError.isEmpty { Text(centsError).font(.caption).foregroundStyle(.orange) }
                        Text("Increasing root-relative integer cents, starting at 0. Optional final 1200. No automatic rounding or makam claim.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(0..<12, id: \.self) { degree in degreeRow(degree) }
                    }
                }.frame(maxHeight: 340)
                Toggle("Allow equal-tempered MIDI approximation", isOn: $draft.allowEqualTemperedMIDI)
                Text("This fallback sends nominal MIDI notes without tuning. Dedicated chord MPE is configured separately in Chord Pads Output. For tuned melodic Touch MIDI choose MPE. Standard MIDI uses the explicit approximation only.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Zero cent offsets") { draft.centOffsets = [:] }
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Apply scale") {
                        var bank = studio.chordBank
                        bank.customScale = draft
                        studio.updateChordBank(bank)
                        editing = false
                    }.buttonStyle(.borderedProminent)
                        .disabled(!draft.isValid || studio.chordArmed)
                }
            }.padding(22).frame(width: 510)
        }
    }

    private var builtInScale:CustomScale {
        var value=CustomScale()
        value.intervals=studio.chordBank.scale.intervals
        return value
    }

    private func degreeRow(_ degree: Int) -> some View {
        let included = draft.intervals.contains(degree)
        return HStack {
            Toggle(degree == 0 ? "Root" : "+\(degree) semitones", isOn: Binding(
                get: { draft.intervals.contains(degree) },
                set: { enabled in
                    if enabled { draft.intervals = Array(Set(draft.intervals + [degree])).sorted() }
                    else {
                        draft.intervals.removeAll { $0 == degree }
                        draft.centOffsets.removeValue(forKey: degree)
                    }
                }
            )).disabled(degree == 0)
            Spacer()
            Stepper("\(draft.centOffsets[degree] ?? 0)¢", value: Binding(
                get: { draft.centOffsets[degree] ?? 0 },
                set: { draft.centOffsets[degree] = $0 }
            ), in: -49...49).disabled(!included || degree == 0)
            Text("\(degree * 100 + (draft.centOffsets[degree] ?? 0))¢")
                .monospacedDigit().frame(width: 65, alignment: .trailing)
        }
    }
}
#endif
