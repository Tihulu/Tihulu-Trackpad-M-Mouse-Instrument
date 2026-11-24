#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore

struct MIDIClipExportButton: View {
    let filename: String
    var title = "Export MIDI"
    let makeClip: () throws -> MIDIClip
    @State private var message = ""
    @State private var showError = false

    var body: some View {
        Button(title) {
            do {
                let data = try MIDIClipWriter.encode(makeClip())
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename + ".mid"
                if let type = UTType(filenameExtension: "mid") { panel.allowedContentTypes = [type] }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            } catch {
                message = error.localizedDescription
                showError = true
            }
        }
        .alert("MIDI export failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
#endif
