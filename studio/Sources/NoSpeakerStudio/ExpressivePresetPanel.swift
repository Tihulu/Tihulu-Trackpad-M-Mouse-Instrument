#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct ExpressivePresetPanel: View {
    @Binding var patch: InstrumentPatch
    @State private var preset: ExpressivePreset = .wah
    @State private var source: SensorSource = .trackpad
    @State private var signal: SensorSignal = .x
    @State private var channel = 1
    @State private var inverted = false
    @State private var message = ""
    @State private var expanded = false

    private var signals: [SensorSignal] { ExpressivePreset.signals(for: source) }
    private var physical: Bool { [.trackpad,.magicMouse,.touchBar,.lid,.camera].contains(source) }
    private var selectedSignal: SensorSignal { preset == .xyFilter ? .x : preset == .tiltEffects ? .tiltRoll : signal }

    var body: some View {
        DisclosureGroup("Add expressive control", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Control", selection: $preset) {
                        ForEach(ExpressivePreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Channel \(channel)", value: $channel, in: 1...16)
                }
                HStack {
                    Picker("Source", selection: $source) {
                        ForEach(ExpressivePreset.sources, id: \.self) {
                            Text(sourceLabel($0)).tag($0)
                        }
                    }
                    if preset == .xyFilter {
                        Text("X + Y").font(.callout)
                    } else if preset == .tiltEffects {
                        Text("Roll + Pitch + Yaw").font(.callout)
                    } else {
                        Picker("Signal", selection: $signal) {
                            ForEach(signals, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Toggle("Invert", isOn: $inverted)
                }
                Text(preset.instructions).font(.caption).foregroundStyle(.secondary)
                Text(physical ? "Native input is experimental; release returns to the configured position. Select Native inputs to test the surface, lid, ribbon or camera." :
                    "Real paired phone/tablet input is available through the Remote panel in Native inputs. Motion sensors require browser permission and explicit arming; simulation is also available.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add to instrument") {
                        do {
                            patch = try preset.appending(to: patch, source: source,
                                                         signal: selectedSignal,
                                                         channel: channel - 1, inverted: inverted)
                            message = "Added to draft. Edit calibration below, then save or start a test."
                        } catch { message = error.localizedDescription }
                    }.disabled(!preset.supports(source: source, signal: selectedSignal) || !patch.isValid)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 6)
        }
        .onChange(of: source) { value in signal = ExpressivePreset.signals(for: value).first ?? .x; message = "" }
        .onChange(of: preset) { _ in message = "" }
    }

    private func sourceLabel(_ source: SensorSource) -> String {
        switch source {
        case .trackpad: "Trackpad"
        case .magicMouse: "Magic Mouse / external touch"
        case .touchBar: "Touch Bar / ribbon (experimental)"
        case .lid: "Lid angle (experimental)"
        case .phone: "Phone (Remote)"
        case .tablet: "Tablet (Remote)"
        case .camera: "Camera / hand (experimental)"
        default: source.rawValue
        }
    }
}
#endif
