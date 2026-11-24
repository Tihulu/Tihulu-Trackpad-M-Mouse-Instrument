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
                        Text("Minimum must not exceed maximum.").font(.caption).foregroundStyle(.orange)
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
