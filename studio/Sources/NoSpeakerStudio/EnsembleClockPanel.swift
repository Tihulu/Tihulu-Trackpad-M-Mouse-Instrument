#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct EnsembleClockPanel: View {
    @EnvironmentObject private var studio:StudioController
    @State private var bpm = 120.0
    @State private var beats = 4
    @State private var sendClock = false
    @State private var tap = TapTempo()
    var body: some View {
        GroupBox("Ensemble transport · host clock") {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Stepper("Tempo: \(Int(bpm)) BPM",value:$bpm,in:20...300,step:1)
                    Stepper("Beats/bar: \(beats)",value:$beats,in:2...7)
                    Button("Tap tempo") {
                        if let next = tap.tap(at:ProcessInfo.processInfo.systemUptime) { bpm = next }
                    }
                }.disabled(studio.ensembleClockRunning)
                HStack {
                    ForEach(1...beats,id:\.self) { beat in
                        Circle().fill(studio.ensembleClockBeat == beat ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width:14,height:14).accessibilityLabel("Beat \(beat)")
                    }
                }
                Toggle("Send MIDI Start / Clock / Stop to TIHULU Ensemble Clock",isOn:$sendClock)
                    .disabled(studio.ensembleClockRunning || !studio.patchMIDIEnabled)
                HStack {
                    Button("Start tempo") {
                        studio.startEnsembleClock(bpm:bpm,beatsPerBar:beats,sendMIDI:sendClock && studio.patchMIDIEnabled)
                    }.disabled(studio.ensembleClockRunning)
                    Button("Stop tempo") { studio.stopEnsembleClock() }
                    Text(studio.ensembleClockStatus).font(.caption)
                }
                Text("Visual beat or opt-in 24 PPQN MIDI clock on a separate source. Enable external sync in the receiving DAW. No audio click, remote clock sync or automatic sequencer start. A missed deadline stops rather than bursts.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
        .onDisappear { studio.stopEnsembleClock() }
        .onChange(of:studio.patchMIDIEnabled) { enabled in if !enabled { sendClock = false } }
    }
}
#endif
