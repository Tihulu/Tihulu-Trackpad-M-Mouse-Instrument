#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore
import NoSpeakerMac

/// Configuration editor only. No endpoints are created and no MIDI is sent.
struct PerformanceGroupEditorView: View {
    let currentPatch: InstrumentPatch
    @EnvironmentObject private var studio: StudioController
    @State private var allowLayering = false
    @State private var hapticSelection:Set<UUID> = []
    @State private var tuningPreview: PerformanceGroupTuningConfiguration?
    @State private var tuningDraft = PerformanceGroupTuningDraft()
    private struct TunedStartSnapshot {
        let tuning:PerformanceGroupTuningConfiguration
        let profile:PerformanceGroupProfile
        let storedData:Data?
        let controllers:[SensorSource:UUID]
        let haptics:Set<UUID>
        let layering:Bool
    }
    @State private var pendingTunedStart:TunedStartSnapshot?
    @State private var confirmTunedStart = false
    @State private var dynamicPreview:DynamicMPEPreview?
    @State private var pendingDynamic:DynamicMPEStartConsent?
    @State private var confirmDynamic = false
    @State private var profile = PerformanceGroupProfile()
    @State private var mobileDraft:PerformanceGroupMobileDraft?
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
            hapticSelection = []
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
                if studio.groupRetainsTuning {
                    Text("Logical mappings only; see retained DAW setup below for wire channels.").font(.caption)
                }
                ForEach(DAWRoutingOverview.rows(for:group.patch)) { row in
                    Text(routeSummary(row)).font(.caption)
                }
                if group.patch.routes.isEmpty {
                    Text("No mappings yet.").font(.caption).foregroundStyle(.secondary)
                }
                groupActions(group)
                remoteRetargetMenu(group)
                mobileEditMenu(group)
                Button("Replace draft mappings from Builder") { replaceMappings(group.id) }
                    .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
            }
        }.disabled(readFailed || editingLocked)
    }

    /// Change a copied Builder group's mobile source without exposing
    /// group-only sources in the legacy Builder source picker.
    @ViewBuilder private func remoteRetargetMenu(_ group:PerformanceInstrumentGroup) -> some View {
        let used = Set(profile.groups.flatMap { $0.patch.routes.map(\.source) })
        let original = SensorSource.groupRemoteSources.filter { source in
            group.patch.routes.contains { $0.source == source }
        }
        let free = SensorSource.groupRemoteSources.filter { !used.contains($0) }
        if !original.isEmpty {
            Menu("Assign mobile slot") {
                ForEach(original,id:\.self) { from in
                    Menu(from.rawValue) {
                        ForEach(free,id:\.self) { to in
                            Button(to.rawValue) {
                                message = profile.reassignRemoteSource(groupID:group.id,from:from,to:to)
                                    ? "Mobile source reassigned in draft. Save and review tuning before Start."
                                    : "Slot reassignment refused; original group retained."
                            }
                        }
                    }
                }
            }.disabled(free.isEmpty || editingLocked)
        }
    }

    private func mobileEditMenu(_ group:PerformanceInstrumentGroup) -> some View {
        Menu("Edit mobile mappings") {
            ForEach(SensorSource.groupRemoteSources,id:\.self) { source in
                Button(source.rawValue) {
                    guard !editingLocked,!readFailed else { return }
                    do { mobileDraft = try .init(profile:profile,groupID:group.id,source:source) }
                    catch { message = "Cannot edit mobile mappings until the group profile is valid." }
                }
            }
        }.disabled(!profile.isValid || editingLocked || readFailed || !didLoad)
    }

    private func applyMobileDraft(_ draft:PerformanceGroupMobileDraft) -> Bool {
        guard !editingLocked,!readFailed,didLoad else { return false }
        do {
            profile = try draft.applying(to:profile)
            message = "Mobile mappings applied to unsaved draft. Save and review any stale tuning before Start."
            return true
        } catch { message = "Mobile draft rejected: " + String(describing:error); return false }
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
        PerformanceGroupGamepadSession.supports(saved,allowSurfaces:true,allowScalars:true,allowCamera:true)
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

    private var remoteSources:[SensorSource] {
        SensorSource.groupRemoteSources.filter { source in saved.groups.contains { group in
            group.patch.routes.contains { $0.source == source }
        } }
    }

    private var supportedRemoteProfile:Bool {
        !remoteSources.isEmpty && PerformanceGroupGamepadSession.supports(saved,allowSurfaces:true,
            allowScalars:true,allowCamera:true,allowRemote:true)
    }

    private func startSavedGroups(tuning: PerformanceGroupTuningConfiguration? = nil,
                                  remoteTransport:RemoteLoopbackTransport? = nil,
                                  remotePage:RemoteLoopbackPageServer? = nil,
                                  confirmedLAN:Bool = false) {
        // A stale editor must not arm a different profile than the saved one.
        guard let data = storedData,
              UserDefaults.standard.data(forKey:key) == data,
              profile == saved, selectedControllersValid,
              (remoteTransport == nil ? canStartGroups : canStartRemoteGroups),
              (remoteTransport == nil) == (remotePage == nil) else {
            message = "Save or reload the current profile and select distinct controllers first."
            return
        }
        guard hapticSelection.isEmpty || (StudioController.groupHapticStartEnabled && hapticSelection.isSubset(of:hapticEligibleIDs) &&
                (tuning == nil || (StudioController.groupTunedHapticStartEnabled && remoteTransport == nil))) else {
            message = "Review Trackpad selection. MPE haptic output requires a separately enabled local Start."
            return
        }
        if let tuning {
            guard StudioController.groupMPEStartEnabled, tuning == tuningPreview,
                  studio.groupRegisteredIDs.isEmpty,
                  (try? tuning.plan(matching:saved)) != nil else {
                message = "MPE Start rejected. Reconfirm a matching preview with no retained ports."
                return
            }
        }
        studio.startGroupGamepads(profile:saved,allowLayering:allowLayering,
            tuning:tuning,confirmedTuning:tuning != nil,remoteTransport:remoteTransport,
            remotePage:remotePage,confirmedLAN:confirmedLAN,hapticGroups:hapticSelection)
    }

    private var canStartGroups: Bool {
        didLoad && !readFailed && !tuningDraft.isDirty && profile == saved && supportedLocalProfile &&
        selectedControllersValid && !studio.groupGamepadsRunning && !studio.groupRetainsTuning &&
        studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0 &&
        (saved.layeredInputs.isEmpty || allowLayering)
    }

    private var canStartRemoteGroups:Bool {
        StudioController.groupRemoteStartEnabled && didLoad && !readFailed && !tuningDraft.isDirty &&
        profile == saved && supportedRemoteProfile && selectedControllersValid &&
        !studio.groupGamepadsRunning && !studio.groupRetainsTuning &&
        studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0 &&
        (saved.layeredInputs.isEmpty || allowLayering)
    }

    private var canStartTunedRemoteGroups:Bool {
        guard canStartRemoteGroups,StudioController.groupMPEStartEnabled,hapticSelection.isEmpty,
              studio.groupRegisteredIDs.isEmpty,let tuningPreview else { return false }
        return (try? tuningPreview.plan(matching:saved)) != nil
    }

    private var canStartTunedGroups: Bool {
        guard StudioController.groupMPEStartEnabled, canStartGroups,
              (hapticSelection.isEmpty || (StudioController.groupTunedHapticStartEnabled && hapticSelection.isSubset(of:hapticEligibleIDs))),
              studio.groupRegisteredIDs.isEmpty, let tuningPreview else { return false }
        return (try? tuningPreview.plan(matching:saved)) != nil
    }

    private func requestTunedStart() {
        guard canStartTunedGroups, let tuningPreview else { return }
        pendingTunedStart = .init(tuning:tuningPreview,profile:saved,storedData:storedData,
            controllers:studio.gamepadBindings,haptics:hapticSelection,layering:allowLayering)
        confirmTunedStart = true
    }

    private var canStartDynamic:Bool {
        guard PerformanceGroupMIDIHost.dynamicMPEEnabled,canStartGroups,
              hapticSelection.isEmpty,studio.groupRegisteredIDs.isEmpty,
              let dynamicPreview,dynamicPreview.profile == saved else { return false }
        return storedData != nil && UserDefaults.standard.data(forKey:key) == storedData
    }

    private var dynamicConsent:DynamicMPEStartConsent? {
        guard canStartDynamic,let dynamicPreview,let storedData else { return nil }
        return .init(profile:saved,tuning:dynamicPreview.tuning,archive:storedData,
            controllers:studio.gamepadBindings,allowLayering:allowLayering,
            cameraID:studio.patchCameraDeviceID,cameraOrientation:studio.patchCameraOrientation,
            cameraMirror:studio.patchCameraMirrorX,mouseOrientation:studio.magicMouseOrientation)
    }

    private func requestDynamicStart() {
        guard let consent = dynamicConsent else { return }
        pendingDynamic = consent
        confirmDynamic = true
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

    @ViewBuilder private func dawSetup(_ group:PerformanceInstrumentGroup) -> some View {
        let registered = studio.groupRegisteredIDs.contains(group.id)
        let status = registered ? registeredStatus(group.id) : "Planned group port; not registered. Start the saved profile to create it."
        if let dynamic = studio.groupDynamicPreview {
            GroupBox("Dynamic MPE DAW setup") {
                VStack(alignment:.leading,spacing:4) {
                    Text(status)
                    Text(group.plannedPortName).textSelection(.enabled)
                    Text("Use the full lower MPE zone (master CH1, members CH2–16). The allocated note channel varies. Setup and receiver reception are not confirmed by this display.")
                    if let planned = dynamic.groups.first(where:{ $0.id == group.id }) {
                        ForEach(planned.routes,id:\.mappingID) { route in
                            Text(route.source.rawValue + " / " + route.signal.rawValue + " → possible CH " +
                                 route.possibleChannels.map { String($0) }.joined(separator:", "))
                        }
                    } else {
                        Text("No prepared dynamic mapping for this group.").foregroundStyle(.orange)
                    }
                }.font(.caption)
            }
        } else if let tuning = studio.groupTunedConfiguration {
            GroupBox("Retained MPE DAW setup") {
                VStack(alignment:.leading,spacing:4) {
                    Text(status)
                    Text(group.plannedPortName).textSelection(.enabled)
                    if let projection = try? PerformanceGroupDAWProjection(profile:saved,configuration:tuning),
                       let planned = projection.groups.first(where:{ $0.id == group.id }) {
                        Text(planned.mode == .lowerMPE ? "Use a compatible lower MPE receiver; master CH1." : "Standard MIDI sibling port.")
                        ForEach(planned.routes,id:\.mappingID) { route in
                            Text(route.source.rawValue + " / " + route.signal.rawValue + " → CH" + String(route.channel))
                        }
                    } else {
                        Text("Retained wire routing could not be verified. Close ports before starting again.").foregroundStyle(.orange)
                    }
                }.font(.caption)
            }
        } else {
            DAWSetupAssistantView(projection:.init(patch:group.patch,sendMIDI:true),
                                  groupPort:.init(name:group.name,port:group.plannedPortName,status:status))
        }
    }

    private var localSources: [SensorSource] {
        Set(saved.groups.flatMap { $0.patch.routes.map(\.source) }).sorted { $0.rawValue < $1.rawValue }
    }

    private func localSourceStatus(_ source:SensorSource) -> String {
        switch studio.groupSourceStates[source] {
        case .waitingForNeutral: return source == .camera ? "Acquiring two reliable frames" : "Waiting for neutral or release; lid may require restart"
        case .armed: return "Armed; awaiting sample"
        case .leased: return "Input lease present; receiver not verified"
        case nil: return "Not bound"
        }
    }

    private var inputReadiness: some View {
        VStack(alignment:.leading,spacing:3) {
            ForEach(localSources,id:\.self) { source in
                HStack {
                    Text(source.rawValue)
                    Spacer()
                    Text(localSourceStatus(source)).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }

    private var unsafeLiveControls: [String] {
        saved.groups.flatMap { group in
            group.patch.routes.filter { !PerformanceGroupGamepadSession.permitsLiveControl($0) }.map {
                group.name + " / CC" + String($0.destination.number)
            }
        }
    }

    private var cameraSetup: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("Camera: one reliable hand, continuous effects only. No images retained or sent. Permission and capture are requested only from Start.")
                .font(.caption)
            Button("Refresh camera choices") { studio.refreshBuilderCameras() }
            Picker("Camera",selection:$studio.patchCameraDeviceID) {
                Text("System default").tag("")
                ForEach(studio.patchCameraChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            Picker("Orientation",selection:$studio.patchCameraOrientation) {
                ForEach(AirControlOrientation.allCases) { orientation in
                    Text(orientation.rawValue).tag(orientation)
                }
            }
            Toggle("Mirror X",isOn:$studio.patchCameraMirrorX)
        }.disabled(studio.groupGamepadsRunning)
    }

    private var hapticEligibleIDs:Set<UUID> {
        Set(saved.groups.filter { $0.patch.routes.contains(where:{ $0.destination.kind == .note }) }.map(\.id))
    }

    @ViewBuilder private var groupHapticControls:some View {
        if StudioController.groupHapticStartEnabled {
            GroupBox("Experimental Trackpad note output") {
                VStack(alignment:.leading,spacing:5) {
                    Text(StudioController.groupTunedHapticStartEnabled ?
                         "Mirror selected standard or locally confirmed fixed-member MPE groups. Remote MPE with Trackpad output is not supported. Off by default; short attacks are best-effort." :
                         "Select standard MIDI groups to mirror on the shared actuator. Off by default. Not MPE, drum synthesis, or audio playback; short attacks are best-effort within a four-entry, 40 ms buffer.")
                        .font(.caption)
                    ForEach(saved.groups.filter { hapticEligibleIDs.contains($0.id) }) { group in
                        Toggle(group.name,isOn:Binding(
                            get:{ hapticSelection.contains(group.id) },
                            set:{ on in
                                if on { hapticSelection.insert(group.id) }
                                else { hapticSelection.remove(group.id) }
                            }))
                        .disabled(studio.groupGamepadsRunning || profile != saved)
                    }
                    Text(studio.groupHapticStatus).font(.caption)
                    Button("Stop Trackpad output only") { studio.stopGroupHaptics() }
                        .disabled(!studio.groupHapticRunning)
                }
            }
        }
    }

    private var liveControls: some View {
        GroupBox("Experimental group MIDI - local controllers and Helpers") {
            VStack(alignment:.leading,spacing:8) {
                Text("Xbox, Trackpad and Magic Mouse may share groups. Touch uses one primary contact; lift each surface to arm. Touch Bar ribbon, compatible lid-angle sensor and single-hand camera support continuous CC and pitch bend only. No pressure or multi-touch. Group Trackpad note output requires its separate experimental build. Live independent MPE requires a separately enabled experimental build.")
                    .font(.caption).foregroundStyle(.secondary)
                if !supportedLocalProfile && !supportedRemoteProfile {
                    Text("Save a supported group profile to enable Start.").font(.caption)
                }
                if !remoteSources.isEmpty && !StudioController.groupRemoteStartEnabled {
                    Text("Mobile group Start is disabled in this build.").font(.caption).foregroundStyle(.orange)
                }
                groupHapticControls
                if supportedRemoteProfile && StudioController.groupRemoteStartEnabled {
                    PerformanceGroupRemotePanel(sources:remoteSources,canStart:canStartRemoteGroups,
                        tuning:tuningPreview,canStartTuned:canStartTunedRemoteGroups) { transport,page,confirmed,tuning in
                        startSavedGroups(tuning:tuning,remoteTransport:transport,remotePage:page,confirmedLAN:confirmed)
                    }
                }
                if localSources.contains(.lid) {
                    Text("Lid input needs a compatible sensor. Start may fail on unsupported Macs; the actual sensor is opened only on Start.").font(.caption)
                }
                if localSources.contains(.touchBar) {
                    Text("Use the native Builder ribbon on a Touch Bar. Registration does not verify that the hardware is present. Release the ribbon after a stall before playing again.").font(.caption)
                }
                if !unsafeLiveControls.isEmpty {
                    Text("Live group safety: CC7 and CC11 need an explicit release value. Bank select and parameter selectors are not supported here. Review: " + unsafeLiveControls.joined(separator:", "))
                        .font(.caption).foregroundStyle(.orange)
                }
                if localSources.contains(.camera) { cameraSetup }
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
                    Button("Start standard MIDI") { startSavedGroups() }
                        .disabled(!canStartGroups)
                    if StudioController.groupMPEStartEnabled {
                        Button("Start group MPE") { requestTunedStart() }
                            .disabled(!canStartTunedGroups)
                    }
                    if PerformanceGroupMIDIHost.dynamicMPEEnabled {
                        Button("Start dynamic MPE") { requestDynamicStart() }
                            .disabled(!canStartDynamic)
                            .confirmationDialog("Start dynamic MPE pools?",isPresented:$confirmDynamic,titleVisibility:.visible) {
                                Button("Confirm dynamic MPE Start") {
                                    guard let consent = pendingDynamic else { return }
                                    pendingDynamic = nil
                                    guard consent == dynamicConsent,let dynamicPreview else {
                                        message = "Dynamic MPE confirmation expired. Review current settings."
                                        return
                                    }
                                    studio.startGroupGamepads(profile:saved,allowLayering:allowLayering,
                                        dynamicPreview:dynamicPreview,confirmedDynamic:true)
                                }
                                Button("Cancel",role:.cancel) { pendingDynamic = nil }
                            } message: {
                                Text("This configures dedicated MPE ports. At most 15 simultaneous member channels per port; individual bend pools may fill sooner. Notes refused at capacity are not replayed. Remote and haptic output are excluded. Receiver setup must be verified manually.")
                            }
                    }
                    Button("Stop / Release All") { studio.stopGroupGamepads() }
                        .disabled(!studio.groupGamepadsRunning)
                    Button("Close ports") { studio.closeGroupPorts() }
                        .disabled(studio.groupGamepadsRunning || studio.groupRegisteredIDs.isEmpty)
                    Button("Retry cleanup") { studio.retryGroupCleanup() }
                        .disabled(studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0)
                }
                Text(studio.groupGamepadStatus).font(.caption)
                if studio.groupDynamicPreview != nil {
                    Text("Dynamic MPE capacity refusals this run: " + String(studio.groupCapacityRefusals) + ". Release and press again after capacity frees. No voice stealing.")
                        .font(.caption).foregroundStyle(studio.groupCapacityRefusals > 0 ? Color.orange : Color.secondary)
                }
                if studio.groupTiming.cycles > 0 {
                    DisclosureGroup("Host timing diagnostics") {
                        let timing = studio.groupTiming
                        Text("Completed cycles: \(timing.cycles) · invalid samples: \(timing.invalidSamples)")
                        Text(String(format:"Peak cycle gap %.1f ms · peak processing %.1f ms",timing.peakGapMS,timing.peakWorkMS))
                        Text("Gaps ≥100 ms: \(timing.gapsAtLeast100MS) · ≥350 ms: \(timing.gapsAtLeast350MS)")
                            .foregroundStyle(timing.gapsAtLeast350MS > 0 ? Color.orange : Color.secondary)
                        Text("Host timing only, not audio latency or confirmed DAW reception. Interrupted final cycles may be absent.")
                            .foregroundStyle(.secondary)
                    }.font(.caption)
                }
                inputReadiness
                Text("\(studio.groupRegisteredIDs.count) registered ports; \(studio.groupCleanupIDs.count) pending MIDI cleanups; \(studio.groupDisposalCount) pending port disposals.")
                    .font(.caption)
                ForEach(saved.groups.filter { studio.groupRegisteredIDs.contains($0.id) }) { group in
                    registeredGroupRow(group)
                }
                if let frozen = studio.groupTunedConfiguration {
                    Text("Retained MPE request. Setup and DAW reception are not certified. Close ports before changing modes.")
                        .font(.caption).foregroundStyle(.orange)
                    if let wire = try? PerformanceGroupDAWProjection(profile:saved,configuration:frozen) {
                        ForEach(wire.groups) { group in
                            VStack(alignment:.leading,spacing:3) {
                                Text(group.name + " | " + group.port).textSelection(.enabled)
                                Text(group.mode == .lowerMPE
                                     ? "MPE: receive the entire lower zone; master CH1; allocated members " +
                                       group.members.map { String($0.channel) }.joined(separator:", ")
                                     : "Standard MIDI channels: " + group.channels.map { String($0) }.joined(separator:", "))
                            }.font(.caption)
                        }
                    } else {
                        Text("Frozen configuration does not match this editor. No channel advice available.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if supportedLocalProfile || supportedRemoteProfile {
                    ForEach(saved.groups.filter { !$0.patch.routes.isEmpty }) { group in
                        dawSetup(group)
                    }
                }
                if tuningDraft.isDirty {
                    Text("Apply or discard unapplied tuning text before starting either MIDI mode.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if tuningPreview != nil && studio.groupTunedConfiguration == nil {
                    Text("Standard MIDI Start deliberately ignores the offline MPE configuration. Use the separately enabled MPE Start for tuned playback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !StudioController.groupMPEStartEnabled {
                    Text("Live MPE is disabled in this build; the tuning editor is offline only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("In Logic Pro select the exact port and appropriate channel or entire MPE zone. Arm tracks and manually verify notes and pedals. Registered does not mean sound is verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        DisclosureGroup("Performance Studio - Instrument Groups (experimental)") {
            VStack(alignment:.leading,spacing:10) {
                Text("Organize note and Helper mappings into named groups. Experimental live group MIDI supports saved Xbox, Trackpad, Magic Mouse, Touch Bar ribbon, lid and single-hand camera Helper profiles. Mobile groups and MPE require their separate experimental build gates.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add empty group") { add(patch:.init()) }
                    Button("Add from Builder draft") { add(patch:currentPatch) }
                        .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
                }.disabled(editingLocked || !didLoad || readFailed || !profile.isValid || profile.groups.count >= PerformanceGroupProfile.maximumGroups)
                Menu("Party Jam starter groups") {
                    ForEach(PerformanceGroupPartyJamPreset.allCases) { preset in
                        Button(preset.title) {
                            message = preset.install(in:&profile)
                                ? preset.detail + " Review and save the draft before Start."
                                : "Starter layout refused; existing draft retained."
                        }
                    }
                }.disabled(editingLocked || !didLoad || readFailed || !profile.groups.isEmpty)
                Text("Starter groups populate an empty draft only. No devices connect until explicit Start.")
                    .font(.caption).foregroundStyle(.secondary)
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
                if didLoad && !readFailed {
                    PerformanceGroupTuningPreviewView(profile:saved,locked:editingLocked || profile != saved,configuration:$tuningPreview,draft:$tuningDraft)
                    DynamicMPEPreviewView(profile:saved,locked:editingLocked || profile != saved,preview:$dynamicPreview)
                }
                liveControls
            }.padding(6)
        }.onAppear { load() }
        .onChange(of:studio.groupGamepadsRunning) { running in
            if !running { hapticSelection = [] }
        }
        .sheet(item:$mobileDraft) { draft in
            PerformanceGroupMobileDraftView(draft:draft,apply:applyMobileDraft)
        }
        .confirmationDialog("Start independent group MPE?",isPresented:$confirmTunedStart,titleVisibility:.visible) {
            Button("Confirm MPE Start") {
                guard let snapshot = pendingTunedStart else { return }
                pendingTunedStart = nil
                guard canStartTunedGroups,snapshot.profile == saved,snapshot.storedData == storedData,
                      snapshot.controllers == studio.gamepadBindings,snapshot.haptics == hapticSelection,
                      snapshot.layering == allowLayering,snapshot.tuning == tuningPreview else {
                    message = "MPE Start confirmation expired. Review the current profile and selections."
                    return
                }
                startSavedGroups(tuning:snapshot.tuning)
            }
            Button("Cancel",role:.cancel) { pendingTunedStart = nil }
        } message: {
            Text("This sends MPE setup and pitch-bend configuration to separate ports. Use compatible DAW instruments. Selected Trackpad groups: " +
                 String(pendingTunedStart?.haptics.count ?? 0) +
                 ". Close retained ports before another Start; closing does not reset the DAW receiver.")
        }
    }
}
#endif
