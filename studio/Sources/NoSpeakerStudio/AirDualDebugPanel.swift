#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Synthetic frames exercise real gesture and routing code; no camera access.
struct AirDualDebugPanel: View {
    @EnvironmentObject private var studio: StudioController
    @State private var streaming = false
    @State private var runID:UUID?
    @State private var count = 0
    @State private var aperture = 0.8
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var chordX = 0.5
    @State private var chordY = 0.5
    @State private var chordAperture = 0.8
    @State private var chordVisible = true
    @State private var helperVisible = true

    var body: some View {
        GroupBox("Dual hand · frame debug") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Synthetic frames · same gesture and MIDI routing as live input. MIDI only if explicitly enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Chord fingers", selection: $count) {
                    ForEach(0...5, id: \.self) { Text(String($0)).tag($0) }
                }.pickerStyle(.segmented)
                Slider(value: $aperture, in: 0...1) { Text("Helper aperture") }
                Slider(value: $x, in: 0...1) { Text("Helper X") }
                Slider(value: $y, in: 0...1) { Text("Helper Y") }
                if studio.patchCombinedDebugAvailable {
                    Toggle("Chord hand visible",isOn:$chordVisible)
                    Toggle("Helper hand visible",isOn:$helperVisible)
                    Slider(value:$chordX,in:0...1) { Text("Chord hand X") }
                    Slider(value:$chordY,in:0...1) { Text("Chord hand Y") }
                    Slider(value:$chordAperture,in:0...1) { Text("Chord hand aperture") }
                }
                Text("Selected: " + (studio.patchAirDebugSelected.map { String($0) } ?? "—") +
                     " · Sounding: " + (studio.patchAirDebugSounding.map { String($0) } ?? "—"))
                    .font(.caption.monospacedDigit())
                HStack {
                    Button("Start frames") {
                        count = 0; aperture = 0.8; runID = studio.patchDebugCameraRunID; streaming = true
                    }.disabled(streaming || studio.patchAirReplaying)
                    Button("Simulate tracking loss") {
                        streaming = false; if let runID,studio.patchDebugCameraRunID == runID { studio.stopAirReplay() }
                    }
                }
                HStack {
                    Text("Recorded frames: \(studio.patchAirTraceCount)").font(.caption.monospacedDigit())
                    Button("Replay trace") { runID = studio.patchDebugCameraRunID; studio.startAirReplay() }
                        .disabled(streaming || studio.patchAirReplaying || studio.patchAirTraceCount == 0 || !studio.patchAirTraceCompatible)
                    Button("Stop replay") { studio.stopAirReplay() }.disabled(!studio.patchAirReplaying)
                    Button("Clear trace") { studio.clearAirTrace() }.disabled(studio.patchAirReplaying)
                }
                Text("Trace is kept in memory only. Replay requires the same camera mode and hand roles, but uses current instrument routes and MIDI settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .task(id: streaming) {
            guard streaming,let runID else { return }
            while !Task.isCancelled && studio.patchAirDebugAvailable && studio.patchDebugCameraRunID == runID {
                studio.sendAirDebugFrame(count:count,aperture:aperture,x:x,y:y,
                    chordHand:AirHandSample.debugSample(x:chordX,y:chordY,aperture:chordAperture),
                    chordVisible:chordVisible,helperVisible:helperVisible,runID:runID)
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        .onChange(of:studio.patchDebugCameraRunID) { _ in streaming = false; runID = nil }
        .onDisappear { streaming = false; if let runID,studio.patchDebugCameraRunID == runID { studio.stopAirReplay() } }
    }
}
#endif
