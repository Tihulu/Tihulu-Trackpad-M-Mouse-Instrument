#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

/// Offline, read-only setup instructions. No MIDI sends, device discovery or DAW automation.
struct DAWSetupAssistantView: View {
    let projection: DAWSetupProjection
    @State private var daw: DAW = .logic

    private enum DAW: String, CaseIterable, Identifiable {
        case logic = "Logic Pro", garage = "GarageBand", live = "Ableton Live", reaper = "REAPER", other = "Other DAW"
        var id: String { rawValue }
        var link: URL? {
            switch self {
            case .logic: return URL(string:"https://support.apple.com/guide/logicpro/lgcp8a4693ee/mac")
            case .garage: return URL(string:"https://support.apple.com/guide/garageband/welcome/mac")
            case .live: return URL(string:"https://www.ableton.com/en/manual/routing-and-i-o/")
            case .reaper: return URL(string:"https://www.reaper.fm/userguide.php")
            case .other: return nil
            }
        }
    }
    private var instructions: [String] {
        switch daw {
        case .logic:
            return [
                "Create a software instrument track for each sound.",
                "In Track Inspector choose MIDI In Port and MIDI In Channel as listed below. For MPE, receive the entire zone instead of a fixed channel.",
                "Record-enable the target tracks. For custom effects use Smart Controls or Controller Assignments; avoid duplicate All Inputs routing."
            ]
        case .garage:
            return ["Create and select a software instrument track. Use a patch containing only the intended sound first.",
                    "Independent port/channel routing and MPE are not verified here. Record separate parts sequentially if necessary."]
        case .live:
            return ["In MIDI settings enable Track for the TIHULU input.",
                    "Set MIDI From to the listed port/channel (all zone channels for MPE); arm the track with Auto monitoring or choose In. Enable Remote only for intended MIDI mapping."]
        case .reaper:
            return ["Enable the TIHULU input in Preferences > MIDI Devices.",
                    "Select the MIDI device/channel in track Input (all zone channels for MPE), arm and enable input monitoring."]
        case .other:
            return ["Enable the MIDI input, select the listed port/channel on the instrument track and enable monitoring."]
        }
    }
    private var statusText: String {
        switch projection.status {
        case .invalid: return "Invalid or incomplete output setup. Fix mappings and output choices first."
        case .disabled: return "MIDI output is off. No DAW routes are enabled."
        case .standard: return "Configured MIDI routes, not a receiver confirmation."
        case .tunedAir: return "Dedicated MPE port: receive all zone channels, use an MPE-compatible instrument and verify bend range. Logical patch channels are not wire channels."
        }
    }
    private var report: String {
        let rows = projection.channels.map { row in
            "CH " + String(row.number) + " | Notes: " + row.notes.joined(separator:", ") + " | Controls: " + row.controls.joined(separator:", ")
        }
        return ([daw.rawValue, statusText, projection.port ?? "—"] + rows + instructions).joined(separator:"\n")
    }
    var body: some View {
        DisclosureGroup("DAW Setup Assistant") {
            VStack(alignment:.leading, spacing:8) {
                HStack {
                    Picker("DAW", selection:$daw) {
                        ForEach(DAW.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let port = projection.port {
                    Text("MIDI Input: " + port).font(.headline).textSelection(.enabled)
                    ForEach(projection.channels) { row in
                        VStack(alignment:.leading, spacing:3) {
                            Text("MIDI Channel " + String(row.number)).font(.headline)
                            Text("Notes: " + (row.notes.isEmpty ? "—" : row.notes.joined(separator:", "))).font(.caption)
                            ForEach(row.controls, id:\.self) { Text($0).font(.caption).textSelection(.enabled) }
                            if row.notes.count > 1 {
                                Text("Shared note channel: these sources share a MIDI address; check that this is intended.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(Array(instructions.enumerated()), id:\.offset) { item in
                        Text(String(item.offset+1) + ". " + item.element).font(.caption)
                    }
                    Text("Manually test one note, pedal and effect at a time. Hearing sound and correct isolation require confirmation in the DAW.").font(.caption).foregroundStyle(.secondary)
                    Button("Copy setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType:.string)
                    }
                }
                if let link = daw.link { Link("Official guide", destination:link) }
            }.padding(6)
        }
    }
}
#endif
