#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct ContinuousResponsePanel: View {
    @Binding var response: ContinuousResponse?
    let target: SensorDestination
    // Unknown input capability must not advertise a relative mode.
    var permitsRelativeInput = false

    private var permitsRelative: Bool {
        permitsRelativeInput && ContinuousResponse.permitsRelative(target)
    }

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
                    positionMode(settings)
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

    @ViewBuilder
    private func positionMode(_ settings: ContinuousResponse) -> some View {
        if permitsRelative {
            Picker("Position mode", selection: Binding(
                get: { response?.relative != nil },
                set: { enabled in
                    guard var next = response else { return }
                    if enabled {
                        guard permitsRelative, next.isValid else { return }
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
                relativeSettings(relative, responseSettings: settings)
            }
        } else if settings.relative != nil {
            Text("Relative is unavailable for this input or target. Select Absolute or choose an eligible continuous route before starting.")
                .font(.caption).foregroundStyle(.orange)
            Button("Use Absolute") {
                if var next = response { next.relative = nil; response = next }
            }
        } else {
            Text("Relative requires a continuous input and an eligible expressive target.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func relativeSettings(_ relative: RelativeControlSettings, responseSettings settings: ContinuousResponse) -> some View {
        if relative.effectiveSource == .manual {
            manualReference(relative, responseSettings: settings)
        } else {
            Text(relative.effectiveSource == .receiverConfirmed ? "Receiver-confirmed reference required" : "Last delivered reference required")
                .font(.caption).foregroundStyle(.orange)
            Text("Live reference provider is not connected in this editor. This route remains silent without verified evidence.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Use manual reference") {
                if var next = response, next.minimum.isFinite, next.maximum.isFinite,
                   (0...1).contains(next.minimum), (0...1).contains(next.maximum), next.minimum <= next.maximum {
                    next.relative?.referenceSource = .manual
                    let reference = next.relative?.reference ?? next.minimum
                    next.relative?.reference = min(next.maximum, max(next.minimum, reference.isFinite ? reference : next.minimum))
                    response = next
                }
            }
        }
        Text("Movement gain: \(relative.gain, specifier: "%.2f")×").font(.caption)
        Slider(value: Binding(get: { response?.relative?.gain ?? 1 }, set: { value in
            if var next = response { next.relative?.gain = value; response = next }
        }), in: 0.25...4, step: 0.25)
        .accessibilityLabel("Movement gain")
        .accessibilityValue(Text(relative.gain.formatted(.number.precision(.fractionLength(2))) + " times"))
        Text("First contact anchors without sending MIDI. Move relative to that point. Manual reference is not DAW feedback. Continuous inputs and exclusive targets only. Existing release policy still applies.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func manualReference(_ relative: RelativeControlSettings, responseSettings settings: ContinuousResponse) -> some View {
        Text("Manual start: \(ContinuousResponse.wireValue(relative.reference, target: target))")
            .font(.caption.monospacedDigit())
        if settings.minimum.isFinite, settings.maximum.isFinite,
           (0...1).contains(settings.minimum), (0...1).contains(settings.maximum),
           settings.minimum <= settings.maximum {
            if relative.reference.isFinite && (settings.minimum...settings.maximum).contains(relative.reference) {
                if settings.minimum < settings.maximum {
                    Slider(value: Binding(get: { min(settings.maximum, max(settings.minimum, response?.relative?.reference ?? settings.minimum)) }, set: { value in
                        if var next = response { next.relative?.reference = value; response = next }
                    }), in: settings.minimum...settings.maximum)
                    .accessibilityLabel("Manual starting value")
                    .accessibilityValue(Text(String(ContinuousResponse.wireValue(relative.reference, target: target))))
                } else {
                    Text("Reference fixed by the output range.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Reference is outside the output range. Correct it before starting.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Set reference within range") {
                    if var next = response {
                        let value = next.relative?.reference ?? settings.minimum
                        next.relative?.reference = min(settings.maximum, max(settings.minimum, value.isFinite ? value : settings.minimum))
                        response = next
                    }
                }
            }
        } else {
            Text("Correct the output range before editing the reference.")
                .font(.caption).foregroundStyle(.orange)
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
