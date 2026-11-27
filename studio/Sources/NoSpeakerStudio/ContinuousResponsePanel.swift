#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct ContinuousResponsePanel: View {
    @Binding var response: ContinuousResponse?
    let target: SensorDestination

    var body: some View {
        DisclosureGroup("Output response") {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Customize response", isOn: Binding(
                    get: { response != nil },
                    set: { response = $0 ? (response ?? ContinuousResponse()) : nil }
                ))
                if let settings = response {
                    parameter("Minimum", key: \.minimum, value: settings.minimum)
                    parameter("Maximum", key: \.maximum, value: settings.maximum)
                    if ContinuousResponse.permitsRelative(target) || settings.relative != nil {
                        Picker("Position mode", selection: Binding(
                            get: { response?.relative != nil },
                            set: { enabled in
                                guard var next = response else { return }
                                if enabled {
                                    guard ContinuousResponse.permitsRelative(target), next.isValid else { return }
                                    let fullScale = target.kind == .pitchBend ? 16383.0 : 127.0
                                    let reference = Double(next.releaseValue(for: target)) / fullScale
                                    next.relative = .init(reference: min(next.maximum, max(next.minimum, reference)))
                                } else { next.relative = nil }
                                response = next
                            }
                        )) {
                            Text("Absolute").tag(false)
                            Text("Relative").tag(true)
                        }.pickerStyle(.segmented)
                        if let relative = settings.relative {
                            Text("Manual start: \(ContinuousResponse.wireValue(relative.reference, target: target))")
                                .font(.caption.monospacedDigit())
                            Slider(value: Binding(get: { response?.relative?.reference ?? 0 }, set: { value in
                                if var next = response { next.relative?.reference = value; response = next }
                            }), in: 0...1)
                            Text("Movement gain: \(relative.gain, specifier: "%.2f")×").font(.caption)
                            Slider(value: Binding(get: { response?.relative?.gain ?? 1 }, set: { value in
                                if var next = response { next.relative?.gain = value; response = next }
                            }), in: 0.25...4, step: 0.25)
                            Text("First contact anchors without sending MIDI. Move relative to that point. Manual reference, not DAW feedback. Continuous inputs and exclusive targets only. Existing release policy still applies.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Smoothing \(settings.smoothingMS) ms").font(.caption)
                        Slider(value: Binding(get: { Double(response?.smoothingMS ?? 0) }, set: { value in
                            if var next = response { next.smoothingMS = Int(value.rounded()); response = next }
                        }), in: 0...250, step: 5)
                    }
                    Toggle("Custom release position", isOn: Binding(
                        get: { response?.release != nil },
                        set: { enabled in
                            if var next = response {
                                next.release = enabled ? Double(ContinuousResponse.defaultRelease(target)) / (target.kind == .pitchBend ? 16383 : 127) : nil
                                response = next
                            }
                        }
                    ))
                    if let release = settings.release {
                        HStack {
                            Text("Release \(ContinuousResponse.wireValue(release, target: target))").font(.caption)
                            Slider(value: Binding(get: { response?.release ?? 0 }, set: { value in
                                if var next = response { next.release = value; response = next }
                            }), in: 0...1)
                        }
                    }
                    Text("Release: \(settings.releaseValue(for: target)). Applies on final source release, Stop and Panic. Smoothing acts on incoming samples; release is immediate. Shared targets must agree on release.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !settings.isValid {
                        Text("Check range and manual reference (must be inside the range).").font(.caption).foregroundStyle(.orange)
                    }
                }
            }.padding(4)
        }
    }

    private func parameter(_ label: String, key: WritableKeyPath<ContinuousResponse, Double>, value: Double) -> some View {
        HStack {
            Text(label + " " + String(ContinuousResponse.wireValue(value, target: target)))
                .font(.caption.monospacedDigit())
            Slider(value: Binding(get: { (response ?? ContinuousResponse())[keyPath: key] }, set: { value in
                if var next = response { next[keyPath: key] = value; response = next }
            }), in: 0...1)
        }
    }
}
#endif
