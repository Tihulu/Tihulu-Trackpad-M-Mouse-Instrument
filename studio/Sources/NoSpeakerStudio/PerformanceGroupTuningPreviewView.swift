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

    @Binding var configuration: PerformanceGroupTuningConfiguration?
    @Binding var draft: PerformanceGroupTuningDraft

    init(profile:PerformanceGroupProfile,locked:Bool,
         configuration:Binding<PerformanceGroupTuningConfiguration?>,
         draft:Binding<PerformanceGroupTuningDraft>) {
        self.profile = profile
        self.locked = locked
        self._configuration = configuration
        self._draft = draft
    }
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
        eligibleGroups.first { $0.id == draft.selectedID }
    }

    private func selectGroup(_ id: UUID?) {
        guard !locked else { return }
        if !draft.select(id,configuration:configuration) {
            message = "Apply or discard text edits before selecting another group."
        }
    }

    private func apply() {
        guard !locked, matchesProfile else { return }
        do {
            let updated = try draft.applying(to:profile,configuration:configuration)
            configuration = updated
            draft.load(draft.selectedID,configuration:updated)
            message = "Tuning preview updated. No MIDI sent. Export to keep this configuration."
        } catch {
            message = "Tuning rejected: " + String(describing:error) + ". Previous preview retained."
        }
    }

    private func removeSelected() {
        guard !locked, !draft.isDirty, matchesProfile, let id = selectedGroup?.id,
              var next = configuration?.tuning, next.removeValue(forKey:id) != nil else { return }
        do {
            let updated: PerformanceGroupTuningConfiguration? = next.isEmpty ? nil :
                try .init(profile:profile,tuning:next)
            configuration = updated
            draft.load(id,configuration:updated)
            message = "Group changed to standard MIDI in the offline preview only."
        } catch {
            message = "Could not remove tuning: " + String(describing:error)
        }
    }

    private func exportConfiguration() {
        guard !locked, !draft.isDirty, matchesProfile, let configuration else { return }
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
        guard !locked, !draft.isDirty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded=try PerformanceGroupTuningConfiguration.read(WorkspaceArchive.readFile(at:url),matching:profile)
            configuration = loaded
            draft.load(eligibleGroups.first(where:{ loaded.tuning[$0.id] != nil })?.id,configuration:loaded)
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
                Text("Edit custom cents and preview actual MIDI wire channels per independent group. Import/export is separate from standard group settings. Live MPE requires a separately enabled experimental build and explicit Start confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                if !matchesProfile {
                    Text("Saved group mappings changed. This tuning is stale. Import a matching file or explicitly reset the preview before editing.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Group",selection:Binding<UUID?>(get:{ draft.selectedID },set:{ selectGroup($0) })) {
                    Text("Select group").tag(UUID?.none)
                    ForEach(eligibleGroups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                TextField("Scale name",text:$draft.scaleName)
                TextField("Scale degrees in cents",text:$draft.degrees)
                TextField("MIDI root (0–127)",text:$draft.rootText)
                if draft.isDirty {
                    Text("Unapplied tuning text. Apply or discard before changing groups, exporting or starting.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Discard text edits") {
                        draft.load(selectedGroup?.id,configuration:configuration)
                        message = "Unapplied text discarded; applied tuning unchanged."
                    }
                }
                Text("Use increasing root-relative cents starting at 0; optional 1200 endpoint. Offsets must fit the existing pitch-class model (±49 cents). This is not a complete makam/seyir editor.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply MPE preview") { apply() }
                        .disabled(selectedGroup == nil || !matchesProfile)
                    Button("Remove selected tuning") { removeSelected() }
                        .disabled(draft.isDirty || draft.selectedID.flatMap { configuration?.tuning[$0] } == nil || !matchesProfile)
                }
                HStack {
                    Button("Import tuning file") { importConfiguration() }.disabled(draft.isDirty)
                    Button("Export tuning file") { exportConfiguration() }
                        .disabled(draft.isDirty || configuration == nil || !matchesProfile)
                    Button("Reset preview") { confirmReset = true }
                        .disabled(configuration == nil && !draft.isDirty)
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
                draft.load(nil,configuration:nil)
                message = "Preview reset. Exported files and standard group settings are unchanged."
            }
            Button("Cancel",role:.cancel) {}
        }
        .onChange(of:profile) { _ in
            if selectedGroup == nil && !draft.isDirty { draft.load(nil,configuration:configuration) }
        }
    }
}
#endif
