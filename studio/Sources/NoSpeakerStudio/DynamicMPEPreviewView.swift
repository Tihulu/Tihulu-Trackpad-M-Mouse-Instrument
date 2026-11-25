#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Separate temporary preview; applies one scale to every nonempty group.
/// Does not change the fixed-member editor, persist tuning, or start MIDI.
struct DynamicMPEPreviewView: View {
    let profile:PerformanceGroupProfile
    let locked:Bool
    @State private var name = "Custom scale"
    @State private var degrees = "0, 180, 400, 500, 700, 900, 1100"
    @State private var root = "60"
    @Binding var preview:DynamicMPEPreview?
    @State private var message = ""

    private func build() {
        guard !locked else { return }
        do {
            let spec = try DynamicMPEPreview.specification(name:name,degrees:degrees,rootText:root)
            let tuning = Dictionary(uniqueKeysWithValues:profile.groups.filter { !$0.patch.routes.isEmpty }.map { ($0.id,spec) })
            preview = try .init(profile:profile,tuning:tuning)
            message = "Offline preview only. No MIDI sent."
        } catch {
            preview = nil
            message = "Dynamic pool rejected: " + String(describing:error)
        }
    }

    var body:some View {
        GroupBox("Dynamic MPE — offline capacity preview") {
            VStack(alignment:.leading,spacing:6) {
                Text("Preview one shared scale across saved groups. Notes can use any available member with their fixed bend. No voice stealing, no more than 15 members per port, and no guarantee all members are available for a given bend. Note, sustain and pitch bend only.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Scale name",text:$name)
                TextField("Degrees in cents",text:$degrees)
                TextField("MIDI root",text:$root)
                Button("Calculate dynamic pools") { build() }
                if let preview,preview.profile == profile {
                    ForEach(preview.groups) { group in
                        DisclosureGroup(group.name + " — " + String(group.plan.mappedNoteCount) + " mapped notes") {
                            Text(group.port).textSelection(.enabled)
                            Text("Master CH1 · " + String(group.plan.members.count) + " members")
                            ForEach(group.plan.channelsPerBend.keys.sorted(),id:\.self) { bend in
                                Text("Bend " + String(bend) + " · " + String(group.plan.channelsPerBend[bend] ?? 0) + " members")
                            }
                            ForEach(group.routes,id:\.mappingID) { route in
                                let input = route.source.rawValue + " / " + route.signal.rawValue
                                let target = route.logical.kind == .note ? "Note " + String(route.logical.number) : route.logical.kind.rawValue
                                let channels = route.possibleChannels.map { String($0) }.joined(separator:", ")
                                Text(input + " → " + target + " · possible CH " + channels)
                            }
                        }.font(.caption)
                    }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.disabled(locked)
        }
        .onChange(of:profile) { _ in preview = nil; message = "" }
        .onChange(of:name) { _ in preview = nil; message = "" }
        .onChange(of:degrees) { _ in preview = nil; message = "" }
        .onChange(of:root) { _ in preview = nil; message = "" }
    }
}
#endif
