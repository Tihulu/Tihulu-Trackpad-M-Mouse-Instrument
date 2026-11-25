#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

/// Configuration editor only. No endpoints are created and no MIDI is sent.
struct PerformanceGroupEditorView: View {
    let currentPatch: InstrumentPatch
    @EnvironmentObject private var studio: StudioController
    @State private var allowLayering = false
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
        guard didLoad, !readFailed, !editingLocked else { return }
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
            allowLayering = false
            message = "Group configuration saved. No new MIDI endpoints created."
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

    private func routeSummary(_ row: DAWRoutingOverview.Row) -> String {
        let channel = String(row.channel + 1)
        let notes = row.noteSources.map { $0.rawValue }.joined(separator:", ")
        let controls = row.controlSources.map { $0.rawValue }.joined(separator:", ")
        return "CH \(channel) | Notes: \(notes) | Helpers: \(controls)"
    }

    private var capacitySummary: String {
        let count = profile.groups.count
        let routes = profile.groups.reduce(0) { $0 + $1.patch.routes.count }
        return "\(count) / \(PerformanceGroupProfile.maximumGroups) groups; \(routes) / \(PerformanceGroupProfile.maximumRoutes) mappings"
    }

    private func groupCard(_ group: PerformanceInstrumentGroup) -> some View {
        GroupBox {
            VStack(alignment:.leading,spacing:5) {
                TextField("Group name",text:nameBinding(group.id))
                Text((studio.groupRegisteredIDs.contains(group.id) ? "Registered port: " : "Planned port: ") + group.plannedPortName)
                    .font(.caption).textSelection(.enabled)
                ForEach(DAWRoutingOverview.rows(for:group.patch)) { row in
                    Text(routeSummary(row)).font(.caption)
                }
                if group.patch.routes.isEmpty {
                    Text("No mappings yet.").font(.caption).foregroundStyle(.secondary)
                }
                groupActions(group)
                Button("Replace draft mappings from Builder") { replaceMappings(group.id) }
                    .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
            }
        }.disabled(readFailed || editingLocked)
    }

    private func groupActions(_ group: PerformanceInstrumentGroup) -> some View {
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
    }

    private var gamepadSources: [SensorSource] {
        let sources = Set(saved.groups.flatMap { $0.patch.routes.map(\.source) })
        return GamepadFrame.orderedSources.filter { sources.contains($0) }
    }

    private var supportedLocalProfile: Bool {
        PerformanceGroupGamepadSession.supports(saved,allowSurfaces:true)
    }

    private var editingLocked: Bool {
        studio.groupGamepadsRunning || !studio.groupRegisteredIDs.isEmpty ||
        !studio.groupCleanupIDs.isEmpty || studio.groupDisposalCount != 0
    }

    private var selectedControllersValid: Bool {
        let ids = gamepadSources.compactMap { studio.gamepadChoice(for:$0) }
        return ids.count == gamepadSources.count && Set(ids).count == ids.count &&
            ids.allSatisfy { id in studio.gamepadChoices.contains { $0.id == id } }
    }

    private func startSavedGroups() {
        // A stale editor must not arm a different profile than the saved one.
        guard let data = storedData,
              UserDefaults.standard.data(forKey:key) == data,
              profile == saved, supportedLocalProfile, selectedControllersValid else {
            message = "Save or reload the current profile and select distinct controllers first."
            return
        }
        studio.startGroupGamepads(profile:saved,allowLayering:allowLayering)
    }

    private var canStartGroups: Bool {
        didLoad && !readFailed && profile == saved && supportedLocalProfile &&
        selectedControllersValid && !studio.groupGamepadsRunning &&
        studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0 &&
        (saved.layeredInputs.isEmpty || allowLayering)
    }

    private func registeredStatus(_ id:UUID) -> String {
        if studio.groupFaultIDs.contains(id) { return "Send fault - group stopped" }
        if studio.groupStoppedIDs.contains(id) { return "Stopped - port retained" }
        return "Port registered; DAW reception not verified"
    }

    private func registeredGroupRow(_ group:PerformanceInstrumentGroup) -> some View {
        HStack {
            VStack(alignment:.leading) {
                Text(group.name)
                Text(group.plannedPortName).font(.caption).textSelection(.enabled)
                Text(registeredStatus(group.id)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop group") { studio.stopPerformanceGroup(group.id) }
                .disabled(!studio.groupGamepadsRunning || studio.groupStoppedIDs.contains(group.id))
        }
    }

    private var liveControls: some View {
        GroupBox("Experimental group MIDI - local controllers and touch surfaces") {
            VStack(alignment:.leading,spacing:8) {
                Text("Standard MIDI only. Xbox, Trackpad and Magic Mouse may share groups. Touch uses one primary contact; lift each surface to arm. No local haptics, pressure, multi-touch, or independent MPE in this preview.")
                    .font(.caption).foregroundStyle(.secondary)
                if !supportedLocalProfile {
                    Text("Save a supported local group profile to enable Start.").font(.caption)
                }
                Button("Refresh controllers") { studio.refreshBuilderGamepads() }
                    .disabled(studio.groupGamepadsRunning)
                ForEach(gamepadSources,id:\.self) { source in
                    Picker(GamepadFrame.slotLabel(source),selection:Binding<UUID?>(
                        get:{ studio.gamepadChoice(for:source) },
                        set:{ studio.setGamepadChoice($0,for:source) })) {
                        Text("Select controller").tag(UUID?.none)
                        ForEach(studio.gamepadChoices) { choice in
                            Text(choice.name).tag(Optional(choice.id))
                        }
                    }.disabled(studio.groupGamepadsRunning)
                }
                if !saved.layeredInputs.isEmpty {
                    Toggle("Allow the same input signal to control multiple groups",isOn:$allowLayering)
                        .disabled(studio.groupGamepadsRunning)
                }
                HStack {
                    Button("Start group MIDI") { startSavedGroups() }
                        .disabled(!canStartGroups)
                    Button("Stop / Release All") { studio.stopGroupGamepads() }
                        .disabled(!studio.groupGamepadsRunning)
                    Button("Close ports") { studio.closeGroupPorts() }
                        .disabled(studio.groupGamepadsRunning || studio.groupRegisteredIDs.isEmpty)
                    Button("Retry cleanup") { studio.retryGroupCleanup() }
                        .disabled(studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0)
                }
                Text(studio.groupGamepadStatus).font(.caption)
                Text("\(studio.groupRegisteredIDs.count) registered ports; \(studio.groupCleanupIDs.count) pending MIDI cleanups; \(studio.groupDisposalCount) pending port disposals.")
                    .font(.caption)
                ForEach(saved.groups.filter { studio.groupRegisteredIDs.contains($0.id) }) { group in
                    registeredGroupRow(group)
                }
                Text("In Logic Pro choose this exact MIDI In Port and the mapped channel for each track. Arm the required tracks; confirm notes and pedals in the DAW. Registered does not mean sound is verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        DisclosureGroup("Performance Studio - Instrument Groups (experimental)") {
            VStack(alignment:.leading,spacing:10) {
                Text("Organize note and Helper mappings into named groups. Experimental live group MIDI supports saved Xbox, Trackpad and Magic Mouse profiles. Other sources still use the existing Builder.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add empty group") { add(patch:.init()) }
                    Button("Add from Builder draft") { add(patch:currentPatch) }
                        .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
                }.disabled(editingLocked || !didLoad || readFailed || !profile.isValid || profile.groups.count >= PerformanceGroupProfile.maximumGroups)
                ForEach(profile.groups) { group in groupCard(group) }
                if !profile.layeredInputs.isEmpty {
                    Text("Shared inputs (layered output requires explicit consent): " +
                         profile.layeredInputs.map(\.id).joined(separator:", "))
                        .font(.caption).foregroundStyle(.orange)
                }
                if !profile.isValid {
                    Text("Fix invalid names or mapping capacity before saving.").font(.caption).foregroundStyle(.orange)
                }
                if editingLocked && !studio.groupGamepadsRunning {
                    Text("Close retained ports and resolve cleanup before editing groups.").font(.caption).foregroundStyle(.secondary)
                }
                Text(capacitySummary)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save groups") { save() }
                        .disabled(editingLocked || !didLoad || readFailed || !profile.isValid || profile == saved)
                    Button("Revert unsaved changes") { profile = saved; message = "Draft reverted." }
                        .disabled(editingLocked || readFailed || profile == saved)
                    Button("Copy planned port list") {
                        let lines = profile.groups.map { group in
                            group.name + (studio.groupRegisteredIDs.contains(group.id) ? " | registered: " : " | planned: ") + group.plannedPortName
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator:"\n"),forType:.string)
                    }.disabled(!profile.isValid || profile.groups.isEmpty || readFailed)
                }
                if profile != saved {
                    Text("Unsaved changes. Save before leaving this screen.").font(.caption).foregroundStyle(.orange)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                liveControls
            }.padding(6)
        }.onAppear { load() }
    }
}
#endif
