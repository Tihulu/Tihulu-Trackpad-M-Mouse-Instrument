#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct AirInstrumentPresetPanel: View {
    @Binding var patch: InstrumentPatch
    @State private var preset: AirInstrumentPreset = .theremin
    @State private var channel = 1
    @State private var note = 60
    @State private var message = ""

    var body: some View {
        DisclosureGroup("Add air instrument") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Instrument", selection: $preset) {
                        ForEach(AirInstrumentPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Channel \(channel)", value: $channel, in: 1...16)
                    if preset != .wah {
                        Stepper("Root MIDI note \(note)", value: $note, in: 0...127)
                    }
                }
                Text(preset.instructions).font(.caption).foregroundStyle(.secondary)
                Text("Experimental single-hand camera mapping. Start with MIDI disabled to calibrate; then route the dedicated Builder MIDI input in your DAW.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add to instrument") {
                    do {
                        patch = try preset.appending(to: patch, channel: channel - 1, note: note)
                        message = "Added editable routes. Save or test explicitly."
                    } catch { message = error.localizedDescription }
                }.disabled(!patch.isValid)
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(.vertical, 6)
        }
    }
}

struct AirCalibrationPanel: View {
    @EnvironmentObject private var studio: StudioController
    @Binding var patch: InstrumentPatch
    @Binding var capture: AirRangeCapture
    @State private var message = ""

    private var mapped: [SensorSignal] {
        [.x,.y,.gesture].filter { signal in
            patch.routes.contains { $0.source == .camera && $0.signal == signal }
        }
    }

    var body: some View {
        DisclosureGroup("Calibrate camera range") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Run a native test with MIDI OFF. Capture two comfortable endpoint poses, stop the test, then apply to all camera routes for the selected signal. Inversion and gate settings stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Signal", selection: $capture.signal) {
                    ForEach(mapped, id: \.self) { signal in
                        Text(signal == .gesture ? "Pinch aperture" : signal.rawValue).tag(signal)
                    }
                }
                .onChange(of: capture.signal) { _ in
                    capture.first = nil; capture.second = nil; message = ""
                }
                HStack {
                    Button("Capture endpoint A") {
                        if let hand = studio.patchCameraHand { capture.first = capture.value(from: hand) }
                    }.disabled(!studio.patchCameraCalibrationAvailable || !mapped.contains(capture.signal))
                    Text(format(capture.first)).monospacedDigit()
                    Button("Capture endpoint B") {
                        if let hand = studio.patchCameraHand { capture.second = capture.value(from: hand) }
                    }.disabled(!studio.patchCameraCalibrationAvailable || !mapped.contains(capture.signal))
                    Text(format(capture.second)).monospacedDigit()
                }
                if let bounds = capture.bounds {
                    Text("Range: " + format(bounds.lowerBound) + " – " + format(bounds.upperBound))
                        .font(.caption)
                } else if capture.first != nil && capture.second != nil {
                    Text("Choose endpoints at least 5% apart.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Apply to draft") {
                        do {
                            patch = try capture.applying(to: patch)
                            message = "Applied to draft. Save or start a new test."
                            capture.first = nil; capture.second = nil
                        } catch { message = error.localizedDescription }
                    }.disabled(studio.patchRunning || capture.bounds == nil || !mapped.contains(capture.signal))
                    Button("Clear") { capture.first = nil; capture.second = nil; message = "" }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(.vertical, 4)
        }.onAppear {
            if !mapped.contains(capture.signal), let first = mapped.first { capture = .init(signal: first) }
        }
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }
}
#endif
