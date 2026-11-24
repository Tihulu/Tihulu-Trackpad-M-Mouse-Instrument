#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct GroovePanel: View {
    @Binding var settings: GrooveSettings?

    private func binding(_ key: WritableKeyPath<GrooveSettings, Int>) -> Binding<Double> {
        Binding(get: { Double((settings ?? GrooveSettings())[keyPath: key]) }, set: { value in
            guard var current = settings else { return }
            current[keyPath: key] = Int(value.rounded())
            settings = current
        })
    }

    var body: some View {
        GroupBox("Groove Controls") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable expressive timing", isOn: Binding(get: { settings != nil }, set: { enabled in
                    settings = enabled ? (settings ?? GrooveSettings()) : nil
                }))
                if let current = settings {
                    HStack {
                        control("Swing", key: \.swing, range: 50...75, value: current.swing)
                        control("Humanize", key: \.humanize, range: 0...100, value: current.humanize)
                    }
                    HStack {
                        control("Intensity", key: \.intensity, range: 25...125, value: current.intensity)
                        control("Probability", key: \.probability, range: 25...100, value: current.probability)
                    }
                    HStack {
                        control("Beat accent", key: \.accent, range: 0...30, value: current.accent)
                        Stepper("Seed \(current.seed)", value: Binding(
                            get: { settings?.seed ?? 1 },
                            set: { value in if var next = settings { next.seed = value; settings = next } }
                        ), in: 1...9999)
                        Button("New variation") {
                            if var next = settings { next.seed = next.seed == 9999 ? 1 : next.seed + 1; settings = next }
                        }
                    }
                    Text("Swing delays alternate sixteenths. Humanize varies timing and velocity, accent emphasizes beats. Probability keeps downbeat hits and selects other hits reproducibly. Play and MIDI export use the same take; changing controls applies on the next Play. The grid remains unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private func control(_ title: String, key: WritableKeyPath<GrooveSettings, Int>,
                         range: ClosedRange<Double>, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) \(value)").font(.caption.monospacedDigit())
            Slider(value: binding(key), in: range, step: 1)
                .accessibilityLabel(title)
        }
    }
}
#endif
