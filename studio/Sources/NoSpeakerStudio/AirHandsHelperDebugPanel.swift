#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct AirHandsHelperDebugPanel: View {
    @EnvironmentObject private var studio: StudioController
    @State private var streaming = false
    @State private var runID:UUID?
    @State private var leftOn = true
    @State private var rightOn = true
    @State private var lx = 0.5
    @State private var ly = 0.5
    @State private var la = 0.8
    @State private var rx = 0.5
    @State private var ry = 0.5
    @State private var ra = 0.8
    var body: some View {
        GroupBox("Camera helper · synthetic frame debug") {
            VStack(alignment:.leading,spacing:8) {
                Text("Independent hand loss and pedal rearm tests. Uses the same helper engine as live Vision.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    VStack {
                        Toggle("Left visible",isOn:$leftOn)
                        Slider(value:$lx,in:0...1) { Text("X") }
                        Slider(value:$ly,in:0...1) { Text("Y") }
                        Slider(value:$la,in:0...1) { Text("Aperture") }
                    }
                    VStack {
                        Toggle("Right visible",isOn:$rightOn)
                        Slider(value:$rx,in:0...1) { Text("X") }
                        Slider(value:$ry,in:0...1) { Text("Y") }
                        Slider(value:$ra,in:0...1) { Text("Aperture") }
                    }
                }
                HStack {
                    Button("Start helper frames") { la = 0.8; ra = 0.8; runID = studio.patchDebugCameraRunID; streaming = true }.disabled(streaming)
                    Button("Stop / release") { streaming = false; if let runID { studio.releaseHelperDebugFrame(runID:runID) } }
                }
            }.padding(8)
        }
        .task(id:streaming) {
            guard streaming,let runID else { return }
            while !Task.isCancelled && studio.patchHelperDebugAvailable && studio.patchDebugCameraRunID == runID {
                studio.sendHelperDebugFrame(left:leftOn ? AirHandSample.debugSample(x:lx,y:ly,aperture:la) : nil,
                                            right:rightOn ? AirHandSample.debugSample(x:rx,y:ry,aperture:ra) : nil,runID:runID)
                do { try await Task.sleep(for:.milliseconds(33)) } catch { return }
            }
        }
        .onChange(of:studio.patchDebugCameraRunID) { _ in streaming = false; runID = nil }
        .onDisappear { streaming = false; if let runID { studio.releaseHelperDebugFrame(runID:runID) } }
    }
}
#endif
