#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore

struct EnsembleTakePanel: View {
    @EnvironmentObject private var studio:StudioController
    @State private var message = ""
    @State private var confirmReplace = false
    var body: some View {
        GroupBox("Ensemble recording · MIDI take") {
            VStack(alignment:.leading,spacing:7) {
                Toggle("Record next Builder run",isOn:Binding(get:{studio.ensembleRecordNext},set:{ value in
                    if value && studio.ensembleTakeReady { confirmReplace = true }
                    else { studio.ensembleRecordNext = value }
                })).disabled(studio.patchRunning)
                Stepper("Export tempo: \(Int(studio.ensembleRecordBPM)) BPM",value:$studio.ensembleRecordBPM,in:20...300,step:1)
                    .disabled(studio.patchRunning)
                HStack {
                    Button("Finish take") { studio.stopEnsembleTake() }.disabled(!studio.ensembleRecording)
                    Button("Export MIDI") { export() }.disabled(!studio.ensembleTakeReady || studio.ensembleRecording)
                    Button("Discard take",role:.destructive) { studio.discardEnsembleTake() }.disabled(!studio.ensembleTakeReady || studio.ensembleRecording)
                }
                Text(studio.ensembleTakeStatus).font(.caption)
                Text("Records reconciled Builder notes, CC, sustain and pitch bend into separate MIDI-channel tracks. Memory only; max 120 seconds / 32,768 events. No video, audio, source identity or DAW-delivery guarantee. Export tempo is fixed; this is not clock or tempo automation. Finishing a take does not stop live instruments.")
                    .font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(6)
        }
        .confirmationDialog("Replace the previous unsaved take on next start?",isPresented:$confirmReplace) {
            Button("Arm recording",role:.destructive) { studio.ensembleRecordNext = true }
            Button("Cancel",role:.cancel) {}
        }
    }
    private func export() {
        do {
            let data = try studio.exportEnsembleTake()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "TIHULU Ensemble Take.mid"
            if let type = UTType(filenameExtension:"mid") { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK,let url = panel.url else { return }
            try data.write(to:url,options:.atomic)
            message = ""
        } catch { message = error.localizedDescription }
    }
}
#endif
