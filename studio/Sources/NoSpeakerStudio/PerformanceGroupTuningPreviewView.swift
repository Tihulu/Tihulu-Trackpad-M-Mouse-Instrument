#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

/// An explicit offline workspace for independent group tuning. This view
/// never starts a performance, modifies the standard group archive or
/// claims that the DAW has accepted a tuning.
struct PerformanceGroupTuningPreviewView: View {
    let profile: PerformanceGroupProfile
    let locked: Bool

    @State private var configuration: PerformanceGroupTuningConfiguration?
    @State private var selectedID: UUID?
    @State private var scaleName = "Custom scale"
    @State private var degrees = "0, 180, 400, 500, 700, 900, 1100"
    @State private var rootText = "60"
    @State private var message = ""
    @State private var confirmReset = false

    private var eligibleGroups: [PerformanceInstrumentGroup] {
        profile.groups.filter { !$0.patch.routes.isEmpty }
    }
    private var matchesProfile: Bool {
        guard let configuration else { return true }
        return (try? configuration.plan(matching:profile)) != nil
    }
    private var projection: PerformanceGroupDAWProjection? {
        try? PerformanceGroupDAWProjection(profile:profile,configuration:configuration)
    }
    private var selectedGroup: PerformanceInstrumentGroup? {
        eligibleGroups.first { $0.id == selectedID }
    }

    private func selectGroup(_ id: UUID?) {
        selectedID = id
        guard let id else { return }
        if let spec = configuration?.tuning[id] {
            scaleName = spec.scale.name
            degrees = spec.scale.degreeCents.map { String($0) }.joined(separator:", ")
            rootText = String(spec.root)
        } else {
            scaleName = "Custom scale"
            degrees = "0, 180, 400, 500, 700, 900, 1100"
            rootText = "60"
        }
    }

    private func apply() {
        guard !locked, matchesProfile, let group = selectedGroup,
              let root = Int(rootText.trimmingCharacters(in:.whitespacesAndNewlines)),
              (0...127).contains(root),
              let scale = CustomScale.fromDegreeCents(degrees,name:scaleName),
              scale.isMicrotonal else {
            message = "Choose a group and a valid microtonal scale/root. No changes made."
            return
        }
        var next = configuration?.tuning ?? [:]
        next[group.id] = .init(scale:scale,root:root)
        do {
            configuration = try .init(profile:profile,tuning:next)
            message = "Tuning preview updated. No MIDI sent. Export to keep this configuration."
        } catch {
            message = "Tuning rejected: " + String(describing:error) + ". Previous preview retained."
        }
    }

    private func removeSelected() {
        guard !locked, matchesProfile, let id = selectedGroup?.id,
              var next = configuration?.tuning, next.removeValue(forKey:id) != nil else { return }
        do {
            let updated: PerformanceGroupTuningConfiguration? = next.isEmpty ? nil :
                try .init(profile:profile,tuning:next)
            configuration = updated
            selectGroup(id)
            message = "Group changed to standard MIDI in the offline preview only."
        } catch {
            message = "Could not remove tuning: " + String(describing:error)
        }
    }

    private func exportConfiguration() {
        guard !locked, matchesProfile, let configuration else { return }
        do {
            // Rebind harmless renames/order changes; never rebind changed mappings.
            let data = try PerformanceGroupTuningConfiguration(profile:profile,tuning:configuration.tuning).archive()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "TIHULU-Group-Tuning.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to:url,options:.atomic)
            message = "Tuning file exported. Standard group settings unchanged."
        } catch {
            message = "Export failed: " + String(describing:error)
        }
    }

    private func importConfiguration() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys:[.isRegularFileKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let handle = try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            let limit = WorkspaceArchive.maximumBytes
            var data = Data()
            while data.count <= limit {
                let remaining = min(65536,limit + 1 - data.count)
                guard let chunk = try handle.read(upToCount:remaining), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= limit else { throw WorkspaceArchiveError.tooLarge }
            let loaded = try PerformanceGroupTuningConfiguration.read(data,matching:profile)
            configuration = loaded
            selectGroup(eligibleGroups.first(where:{ loaded.tuning[$0.id] != nil })?.id)
            message = "Tuning file imported and matched to saved groups. No MIDI sent."
        } catch {
            message = "Import rejected: " + String(describing:error) + ". Previous preview retained."
        }
    }

    private func routeLabel(_ destination: SensorDestination) -> String {
        switch destination.kind {
        case .note: return "Note " + String(destination.number)
        case .sustain: return "CC64 Sustain"
        case .pitchBend: return "Pitch Bend"
        case .controlChange: return "CC" + String(destination.number)
        }
    }

    private func groupPreview(_ group: PerformanceGroupDAWProjection.Group) -> some View {
        DisclosureGroup(group.name + (group.mode == .lowerMPE ? " — MPE" : " — Standard MIDI")) {
            VStack(alignment:.leading,spacing:4) {
                Text("Planned MIDI port: " + group.port).textSelection(.enabled)
                if group.mode == .lowerMPE {
                    Text("Lower MPE zone: master CH1; allocated members " +
                         group.members.map { "CH" + String($0.channel) }.joined(separator:", "))
                    Text("Use an MPE-compatible receiver for the full zone. The fixed member plan supports at most 15 distinct mapped notes. Verify receiver tuning and bend ranges manually.")
                    ForEach(group.members,id:\.channel) { member in
                        Text("CH" + String(member.channel) + " | setup bend " + String(member.bend))
                    }
                }
                ForEach(Array(group.routes.enumerated()),id:\.offset) { item in
                    let route = item.element
                    Text(route.source.rawValue + " / " + route.signal.rawValue + " → CH" +
                         String(route.channel) + " " + routeLabel(route.wire))
                }
            }.font(.caption).padding(4)
        }
    }

    var body: some View {
        GroupBox("Independent group tuning — offline preview") {
            VStack(alignment:.leading,spacing:8) {
                Text("Edit custom cents and preview actual MIDI wire channels per independent group. Import/export is separate from standard group settings. This preview is not connected to live Start.")
                    .font(.caption).foregroundStyle(.secondary)
                if !matchesProfile {
                    Text("Saved group mappings changed. This tuning is stale. Import a matching file or explicitly reset the preview before editing.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Group",selection:Binding<UUID?>(get:{ selectedID },set:{ selectGroup($0) })) {
                    Text("Select group").tag(UUID?.none)
                    ForEach(eligibleGroups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                TextField("Scale name",text:$scaleName)
                TextField("Scale degrees in cents",text:$degrees)
                TextField("MIDI root (0–127)",text:$rootText)
                Text("Use increasing root-relative cents starting at 0; optional 1200 endpoint. Offsets must fit the existing pitch-class model (±49 cents). This is not a complete makam/seyir editor.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply MPE preview") { apply() }
                        .disabled(selectedGroup == nil || !matchesProfile)
                    Button("Remove selected tuning") { removeSelected() }
                        .disabled(selectedID.flatMap { configuration?.tuning[$0] } == nil || !matchesProfile)
                }
                HStack {
                    Button("Import tuning file") { importConfiguration() }
                    Button("Export tuning file") { exportConfiguration() }
                        .disabled(configuration == nil || !matchesProfile)
                    Button("Reset preview") { confirmReset = true }
                        .disabled(configuration == nil)
                }
                if let projection {
                    ForEach(projection.groups) { group in groupPreview(group) }
                } else {
                    Text("No valid wire-channel preview. Review the saved profile and tuning.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.disabled(locked)
        }
        .confirmationDialog("Reset offline tuning preview?",isPresented:$confirmReset,titleVisibility:.visible) {
            Button("Reset preview",role:.destructive) {
                guard !locked else { return }
                configuration = nil
                selectGroup(nil)
                message = "Preview reset. Exported files and standard group settings are unchanged."
            }
            Button("Cancel",role:.cancel) {}
        }
        .onChange(of:profile) { _ in
            if selectedGroup == nil { selectGroup(nil) }
        }
    }
}
#endif
