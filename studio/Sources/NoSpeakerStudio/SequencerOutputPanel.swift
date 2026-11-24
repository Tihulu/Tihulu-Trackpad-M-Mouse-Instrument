#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct SequencerOutputPanel: View {
    @EnvironmentObject private var studio: StudioController
    @Binding var output: MusicalOutput?

    var body: some View {
        GroupBox("Sequencer output") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Destination", selection: Binding(
                        get: { output ?? .haptic }, set: { output = $0 }
                    )) {
                        ForEach(MusicalOutput.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(studio.sequenceRunning)
                    Button("Stop MIDI sequence") { studio.stopLiveSequence() }
                }
                Text(studio.sequenceStatus).font(.caption)
                if (output ?? .haptic).sendsMIDI {
                    Text("Choose TIHULU Sequencer as the DAW input. Notes use channel 1, drums channel 10. One live MIDI sequence at a time; changes apply at next Play. Both uses exclusive Trackpad playback and a separate MIDI schedule; timing alignment is experimental. No DAW clock sync yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }
}
#endif
