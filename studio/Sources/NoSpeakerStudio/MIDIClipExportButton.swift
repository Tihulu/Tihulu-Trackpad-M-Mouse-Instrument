#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore

struct MIDIClipExportButton: View {
    let filename: String
    var title = "Export MIDI"
    var makeClip: (() throws -> MIDIClip)?
    var makeData: (() throws -> Data)?
    init(filename:String,title:String = "Export MIDI",makeClip:@escaping () throws -> MIDIClip) {
        self.filename = filename; self.title = title; self.makeClip = makeClip
    }
    init(filename:String,title:String,makeData:@escaping () throws -> Data) {
        self.filename = filename; self.title = title; self.makeData = makeData
    }
    @State private var message = ""
    @State private var showError = false

    var body: some View {
        Button(title) {
            do {
                let data:Data
                if let makeData { data = try makeData() }
                else if let makeClip { data = try MIDIClipWriter.encode(makeClip()) }
                else { throw MIDIClipError.invalidClip }
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
