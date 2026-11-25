#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

/// Configuration editor only. No endpoints are created and no MIDI is sent.
struct PerformanceGroupEditorView: View {
    let currentPatch: InstrumentPatch
    @State private var profile = PerformanceGroupProfile()
    @State private var saved = PerformanceGroupProfile()
    @State private var storedData: Data?
    @State private var didLoad = false
    @State private var readFailed = false
    @State private var message = ""
    private let key = "TIHULU.performanceGroups.v1"

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let stored = UserDefaults.standard.object(forKey:key) else { return }
        guard let data = stored as? Data,
              let decoded = try? PerformanceGroupProfile.read(data) else {
            readFailed = true
            message = "Saved group profile could not be read. Original data retained; saving is blocked."
            return
        }
        profile = decoded
        saved = decoded
        storedData = data
    }

    private func save() {
        guard didLoad, !readFailed else { return }
        let current = UserDefaults.standard.object(forKey:key)
        guard (current == nil && storedData == nil) ||
              (current is Data && (current as? Data) == storedData) else {
            message = "Saved profile changed elsewhere. Reopen this editor before saving. Your draft was not written."
            return
        }
        do {
            let data = try profile.archive()
            UserDefaults.standard.set(data,forKey:key)
            storedData = data
            saved = profile
            message = "Group configuration saved. No MIDI endpoints created."
        } catch {
            message = error.localizedDescription
        }
    }

    private func add(patch: InstrumentPatch) {
        let name = "Instrument " + String(profile.groups.count + 1)
        message = profile.add(.init(name:name,patch:patch))
            ? "Group added to draft." : "Invalid configuration or group/route capacity reached."
    }

    private func replaceMappings(_ id: UUID) {
        guard let index = profile.groups.firstIndex(where:{ $0.id == id }) else { return }
        var next = profile
        next.groups[index].patch = currentPatch
        guard next.isValid else {
            message = "Cannot replace mappings: invalid patch or route capacity."
            return
        }
        profile = next
        message = "Draft mappings replaced. Save to keep this change, or Revert."
    }

    private func moveUp(_ id: UUID) {
        guard let index = profile.groups.firstIndex(where:{ $0.id == id }), index > 0 else { return }
        profile.groups.swapAt(index,index-1)
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(get:{ profile.groups.first(where:{ $0.id == id })?.name ?? "" },
                set:{ name in
                    guard let index = profile.groups.firstIndex(where:{ $0.id == id }) else { return }
                    profile.groups[index].name = name
                })
    }

    var body: some View {
        DisclosureGroup("Performance Studio - Instrument Groups (configuration preview)") {
            VStack(alignment:.leading,spacing:10) {
                Text("Organize note and Helper mappings into named groups. Independent MIDI ports are planned, not active. Use the existing Builder to play music.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add empty group") { add(patch:.init()) }
                    Button("Add from Builder draft") { add(patch:currentPatch) }
                        .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
                }.disabled(!didLoad || readFailed || !profile.isValid || profile.groups.count >= PerformanceGroupProfile.maximumGroups)
                ForEach(profile.groups) { group in
                    GroupBox {
                        VStack(alignment:.leading,spacing:5) {
                            TextField("Group name",text:nameBinding(group.id))
                            Text("Planned port (not registered): " + group.plannedPortName)
                                .font(.caption).textSelection(.enabled)
                            ForEach(DAWRoutingOverview.rows(for:group.patch)) { row in
                                Text("CH " + String(row.channel+1) + " | Notes: " +
                                     row.noteSources.map(\.rawValue).joined(separator:", ") + " | Helpers: " +
                                     row.controlSources.map(\.rawValue).joined(separator:", "))
                                    .font(.caption)
                            }
                            if group.patch.routes.isEmpty {
                                Text("No mappings yet.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Copy group") {
                                    message = profile.duplicate(group.id) ? "Group copied with a new identity." : "Cannot copy: invalid profile or capacity."
                                }.disabled(!profile.isValid || profile.groups.count >= PerformanceGroupProfile.maximumGroups)
                                Button("Move up") { moveUp(group.id) }
                                    .disabled(profile.groups.first?.id == group.id)
                                Button("Delete from draft") {
                                    profile.groups.removeAll { $0.id == group.id }
                                }
                            }
                            Button("Replace draft mappings from Builder") { replaceMappings(group.id) }
                                .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
                        }
                    }.disabled(readFailed)
                }
                if !profile.layeredInputs.isEmpty {
                    Text("Shared inputs (future layered output requires explicit consent): " +
                         profile.layeredInputs.map(\.id).joined(separator:", "))
                        .font(.caption).foregroundStyle(.orange)
                }
                if !profile.isValid {
                    Text("Fix invalid names or mapping capacity before saving.").font(.caption).foregroundStyle(.orange)
                }
                Text(String(profile.groups.count) + " / " + String(PerformanceGroupProfile.maximumGroups) + " groups; " +
                     String(profile.groups.reduce(0) { $0 + $1.patch.routes.count }) + " / " +
                     String(PerformanceGroupProfile.maximumRoutes) + " mappings")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save groups") { save() }
                        .disabled(!didLoad || readFailed || !profile.isValid || profile == saved)
                    Button("Revert unsaved changes") { profile = saved; message = "Draft reverted." }
                        .disabled(readFailed || profile == saved)
                    Button("Copy planned port list") {
                        let lines = profile.groups.map { $0.name + " | planned only: " + $0.plannedPortName }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator:"\n"),forType:.string)
                    }.disabled(!profile.isValid || profile.groups.isEmpty || readFailed)
                }
                if profile != saved {
                    Text("Unsaved changes. Save before leaving this screen.").font(.caption).foregroundStyle(.orange)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(6)
        }.onAppear { load() }
    }
}
#endif
