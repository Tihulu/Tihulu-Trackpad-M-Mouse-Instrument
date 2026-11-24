#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct ArpeggioPanel: View {
    @EnvironmentObject private var studio: StudioController
    private var enabled: Binding<Bool> {
        Binding(get: { studio.chordProgression.arpeggio != nil }, set: { enabled in
            var next = studio.chordProgression
            next.arpeggio = enabled ? (next.arpeggio ?? ArpeggioSettings()) : nil
            studio.updateChordProgression(next)
        })
    }

    private func setting<T>(_ key: WritableKeyPath<ArpeggioSettings, T>) -> Binding<T> {
        Binding(get: { (studio.chordProgression.arpeggio ?? ArpeggioSettings())[keyPath: key] },
                set: { value in
            var next = studio.chordProgression
            guard var arp = next.arpeggio else { return }
            arp[keyPath: key] = value
            next.arpeggio = arp
            studio.updateChordProgression(next)
        })
    }

    var body: some View {
        GroupBox("Arpeggiator") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Arpeggiate progression", isOn: enabled)
                if let arp = studio.chordProgression.arpeggio {
                    HStack {
                        Picker("Order", selection: setting(\.order)) {
                            ForEach(ArpeggioOrder.allCases) { order in Text(order.rawValue).tag(order) }
                        }
                        Picker("Notes / beat", selection: setting(\.notesPerBeat)) {
                            ForEach([1,2,3,4,6,8], id: \.self) { Text(String($0)).tag($0) }
                        }
                        Stepper("Octaves \(arp.octaves)", value: setting(\.octaves), in: 1...3)
                    }
                    if arp.order == .shuffle {
                        Stepper("Shuffle seed \(arp.seed)", value: setting(\.seed), in: 1...9999)
                    }
                    Text("The same gate percentage now applies to each note. Order restarts at each chord; a pad’s Arp button plays just that chord using these settings. Ordinary pad buttons still play full chords. Uses the bank’s selected output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }
}
#endif
