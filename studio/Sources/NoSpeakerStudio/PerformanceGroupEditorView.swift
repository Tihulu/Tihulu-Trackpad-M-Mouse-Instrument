#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NoSpeakerCore
import NoSpeakerMac

/// Configuration editor only. No endpoints are created and no MIDI is sent.
struct PerformanceGroupEditorView: View {
    let currentPatch: InstrumentPatch
    let editInBuilder:(InstrumentPatch)->Void
    @State private var starter:PerformanceGroupStarterPreset = .trackpadSolo
    @State private var groupsExpanded=false
    @State private var confirmStarterReplacement=false
    @State private var pendingStarter:PerformanceGroupStarterPreset?
    @State private var pendingStarterDraft:PerformanceGroupProfile?
    @State private var pendingImport:PerformanceGroupProfile?
    @State private var pendingImportDraft:PerformanceGroupProfile?
    @State private var confirmImport=false
    @State private var presetLibrary=PerformanceGroupPresetLibrary()
    @State private var libraryData:Data?
    @State private var libraryLoaded=false
    @State private var libraryReadFailed=false
    @State private var libraryName=""
    @State private var librarySelection:UUID?
    @State private var libraryMessage=""
    @State private var pendingLibraryDelete:PerformanceGroupPresetLibrary.Entry?
    @State private var confirmLibraryDelete=false
    @State private var pendingLibraryUpdate:PerformanceGroupPresetLibrary.Entry?
    @State private var pendingLibraryUpdateProfile:PerformanceGroupProfile?
    @State private var confirmLibraryUpdate=false
    @State private var renamePresetName=""
    private let libraryKey="TIHULU.performanceGroupPresetLibrary.v1"
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
        let deviceConsent:DynamicMPEStartConsent
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
        guard let stored = UserDefaults.standard.object(forKey:key) else {
            profile=studio.resumeGroupDraft(saved:saved,archive:nil)
            return
        }
        guard let data = stored as? Data,
              let decoded = try? PerformanceGroupProfile.read(data) else {
            readFailed = true
            message = "Saved group profile could not be read. Original data retained; saving is blocked."
            return
        }
        saved = decoded
        storedData = data
        profile=studio.resumeGroupDraft(saved:decoded,archive:data)
    }

    @discardableResult
    private func save() -> Bool {
        guard didLoad, !readFailed, !editingLocked,!studio.patchRunning else { return false }
        let current = UserDefaults.standard.object(forKey:key)
        guard (current == nil && storedData == nil) ||
              (current is Data && (current as? Data) == storedData) else {
            message = "Saved profile changed elsewhere. Reopen this editor before saving. Your draft was not written."
            return false
        }
        do {
            let data = try profile.archive()
            UserDefaults.standard.set(data,forKey:key)
            storedData = data
            saved = profile
            studio.discardGroupDraft()
            allowLayering = false
            hapticSelection = []
            message = "Group configuration saved. No new MIDI endpoints created."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func rememberGroupDraft() {
        guard didLoad,!readFailed else { return }
        studio.rememberGroupDraft(profile,saved:saved,archive:storedData)
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
                Button("Edit a copy in Builder") { editInBuilder(group.patch) }
                    .disabled(!group.patch.isValid || group.patch.routes.isEmpty ||
                              group.patch.routes.contains(where:{ $0.source.isGroupOnlyRemote }))
                if group.patch.routes.contains(where:{ $0.source.isGroupOnlyRemote }) {
                    Text("Use Edit mobile mappings for additional mobile slots.").font(.caption).foregroundStyle(.secondary)
                }
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
        guard canStartRemoteGroups,StudioController.groupMPEStartEnabled,hapticSelection.isEmpty,currentTunedConsent != nil,
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
        guard canStartTunedGroups, let tuningPreview,let deviceConsent = currentTunedConsent else { return }
        pendingTunedStart = .init(tuning:tuningPreview,profile:saved,storedData:storedData,
            controllers:studio.gamepadBindings,haptics:hapticSelection,layering:allowLayering,deviceConsent:deviceConsent)
        confirmTunedStart = true
    }

    private var canStartDynamic:Bool {
        guard PerformanceGroupMIDIHost.dynamicMPEEnabled,canStartGroups,
              (hapticSelection.isEmpty || (PerformanceGroupMIDIHost.dynamicMPEHapticsEnabled && hapticSelection.isSubset(of:hapticEligibleIDs))),
              studio.groupRegisteredIDs.isEmpty,let dynamicPreview,dynamicPreview.profile == saved else { return false }
        return storedData != nil && UserDefaults.standard.data(forKey:key) == storedData
    }

    private var currentTunedConsent:DynamicMPEStartConsent? {
        guard let tuningPreview else { return nil }
        return startConsent(tuning:tuningPreview.tuning)
    }

    private var dynamicConsent:DynamicMPEStartConsent? {
        guard canStartDynamic,let dynamicPreview else { return nil }
        return startConsent(tuning:dynamicPreview.tuning)
    }

    private func startConsent(tuning:[UUID:PerformanceGroupTuningPlan.Specification]) -> DynamicMPEStartConsent? {
        guard let storedData,profile == saved,UserDefaults.standard.data(forKey:key) == storedData else { return nil }
        return .init(profile:saved,tuning:tuning,archive:storedData,
            controllers:studio.gamepadBindings,allowLayering:allowLayering,
            cameraID:studio.patchCameraDeviceID,cameraOrientation:studio.patchCameraOrientation,
            cameraMirror:studio.patchCameraMirrorX,mouseOrientation:studio.magicMouseOrientation,hapticGroups:hapticSelection)
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
                            let input = route.source.rawValue + " / " + route.signal.rawValue
                            let channels = route.possibleChannels.map { String($0) }.joined(separator:", ")
                            Text(input + " → possible CH " + channels)
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
                    Text(PerformanceGroupMIDIHost.dynamicMPEHapticsEnabled ?
                         "Mirror selected standard or explicitly confirmed local fixed/dynamic MPE groups. Dynamic MPE uses fixed-bend member pools. Off by default; short attacks are best-effort." : StudioController.groupTunedHapticStartEnabled ?
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
                        tuning:tuningPreview,canStartTuned:canStartTunedRemoteGroups,tunedConsent:currentTunedConsent) { transport,page,confirmed,tuning,consent in
                        guard tuning == nil || (consent != nil && consent == currentTunedConsent && hapticSelection.isEmpty) else {
                            message = "Remote MPE confirmation expired. Review profile and device settings."
                            return
                        }
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
                                        hapticGroups:consent.hapticGroups,dynamicPreview:dynamicPreview,confirmedDynamic:true)
                                }
                                Button("Cancel",role:.cancel) { pendingDynamic = nil }
                            } message: {
                                Text("This configures dedicated MPE ports. At most 15 simultaneous member channels per port; individual bend pools may fill sooner. Notes refused at capacity are not replayed. Remote output is excluded. Selected Trackpad groups: " + String(pendingDynamic?.hapticGroups.count ?? 0) + ". Receiver setup must be verified manually.")
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

    private func loadStarter(_ preset:PerformanceGroupStarterPreset,append:Bool) {
        guard didLoad,!readFailed,!editingLocked,!studio.patchRunning else { return }
        guard !tuningDraft.isDirty else {
            message="Apply or discard pending tuning edits before loading a preset."
            groupsExpanded=true
            return
        }
        let next=append ? preset.appending(to:profile) : preset.makeProfile()
        guard let next else {
            message="Preset unavailable or conflicts with existing inputs/capacity. Existing draft retained."
            return
        }
        profile=next
        allowLayering=false
        hapticSelection=[]
        groupsExpanded=false
        message=preset.title + " loaded as editable draft. Save & Start or open Device setup / advanced."
    }

    private func sourceLabel(_ source:SensorSource) -> String {
        switch source {
        case .trackpad: "Trackpad"
        case .magicMouse: "Magic Mouse"
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .phone2: "Phone 2"
        case .tablet2: "Tablet 2"
        case .camera: "Camera"
        case .touchBar: "Touch Bar"
        case .lid: "Lid sensor"
        default: GamepadFrame.slotLabel(source)
        }
    }

    private func exportGroupDraft() {
        guard didLoad,!readFailed,profile.isValid else { return }
        do {
            let data=try profile.archive()
            let panel=NSSavePanel()
            panel.allowedContentTypes=[.json]
            panel.nameFieldStringValue="TIHULU Groups.json"
            guard panel.runModal() == .OK,let url=panel.url else { return }
            try data.write(to:url,options:.atomic)
            message="Group layout exported. Device assignments and MPE configuration are not included."
        } catch { message=error.localizedDescription }
    }

    private func importGroupDraft() {
        guard didLoad,!readFailed,!editingLocked,!studio.patchRunning,!tuningDraft.isDirty else { return }
        let original=profile
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.json]
        panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url,!editingLocked,!studio.patchRunning,
              !tuningDraft.isDirty,profile==original else { return }
        do {
            let decoded=try PerformanceGroupProfile.read(WorkspaceArchive.readFile(at:url))
            if profile.groups.isEmpty { applyImportedGroupDraft(decoded) }
            else {
                pendingImport=decoded
                pendingImportDraft=original
                confirmImport=true
            }
        } catch { message=error.localizedDescription }
    }

    private func applyImportedGroupDraft(_ imported:PerformanceGroupProfile) {
        guard didLoad,!readFailed,!editingLocked,!studio.patchRunning,!tuningDraft.isDirty,
              imported.isValid else { return }
        profile=imported
        allowLayering=false
        hapticSelection=[]
        groupsExpanded=false
        message="Loaded editable group layout. Original port identities retained; save and review devices before Start."
    }

    private func loadPresetLibrary() {
        guard !libraryLoaded else { return }
        libraryLoaded=true
        guard let raw=UserDefaults.standard.object(forKey:libraryKey) else { return }
        guard let data=raw as? Data,let decoded=try? PerformanceGroupPresetLibrary.read(data) else {
            libraryReadFailed=true
            libraryMessage="Custom preset library could not be read. Original data retained; library changes blocked."
            return
        }
        presetLibrary=decoded
        libraryData=data
        librarySelection=decoded.entries.first?.id
    }

    @discardableResult
    private func storePresetLibrary(_ next:PerformanceGroupPresetLibrary) -> Bool {
        guard libraryLoaded,!libraryReadFailed,!editingLocked,!studio.patchRunning else { return false }
        let current=UserDefaults.standard.object(forKey:libraryKey)
        guard (current==nil && libraryData==nil) || (current is Data && (current as? Data)==libraryData) else {
            libraryMessage="Preset library changed elsewhere. Reopen this screen before editing."
            return false
        }
        do {
            let data=try next.archive()
            UserDefaults.standard.set(data,forKey:libraryKey)
            presetLibrary=next
            libraryData=data
            return true
        } catch { libraryMessage=error.localizedDescription;return false }
    }

    private func saveNamedPreset() {
        guard didLoad,!readFailed,!tuningDraft.isDirty,profile.isValid,!profile.groups.isEmpty else { return }
        var next=presetLibrary
        let id=UUID()
        guard next.add(name:libraryName,profile:profile,id:id) else {
            libraryMessage="Preset not added. Choose a unique name or free library space; existing presets unchanged."
            return
        }
        guard storePresetLibrary(next) else { return }
        librarySelection=id
        libraryName=""
        libraryMessage="Editable copy saved to My Presets. Active saved layout unchanged."
    }

    private func recallNamedPreset() {
        guard libraryLoaded,!libraryReadFailed,!editingLocked,!studio.patchRunning,
              didLoad,!readFailed,!tuningDraft.isDirty,
              let entry=presetLibrary.entries.first(where:{$0.id==librarySelection}) else { return }
        if profile==entry.profile {
            libraryMessage="This layout is already loaded."
            return
        }
        if profile.groups.isEmpty { applyImportedGroupDraft(entry.profile) }
        else {
            pendingImport=entry.profile
            pendingImportDraft=profile
            confirmImport=true
        }
    }

    private var userPresetPanel:some View {
        GroupBox("My presets · local layouts") {
            VStack(alignment:.leading,spacing:6) {
                Text("Keep multiple personal instruments and jam setups. Factory presets stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("New preset name",text:$libraryName)
                Button("Save current draft as new preset") { saveNamedPreset() }
                    .disabled(libraryName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
                              !profile.isValid || profile.groups.isEmpty || tuningDraft.isDirty)
                Picker("Saved preset",selection:$librarySelection) {
                    Text("Select a preset").tag(UUID?.none)
                    ForEach(presetLibrary.entries) { entry in
                        Text(entry.name).tag(Optional(entry.id))
                    }
                }
                if let entry=presetLibrary.entries.first(where:{$0.id==librarySelection}) {
                    Text("\(entry.profile.groups.count) groups · \(entry.profile.groups.reduce(0) { $0+$1.patch.routes.count }) mappings")
                        .font(.caption)
                    HStack {
                        TextField("Rename selected preset",text:$renamePresetName)
                        Button("Rename") {
                            var next=presetLibrary
                            guard next.update(expected:entry,name:renamePresetName,profile:entry.profile),
                                  storePresetLibrary(next) else {
                                libraryMessage="Rename refused. Choose a unique valid name or reload the library."
                                return
                            }
                            renamePresetName=""
                            libraryMessage="Preset renamed. Mappings and port identities unchanged."
                        }.disabled(renamePresetName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                    Button("Update selected preset from current draft") {
                        pendingLibraryUpdate=entry
                        pendingLibraryUpdateProfile=profile
                        confirmLibraryUpdate=true
                    }.disabled(!profile.isValid || profile.groups.isEmpty || profile==entry.profile || tuningDraft.isDirty)
                }
                HStack {
                    Button("Load editable copy") { recallNamedPreset() }
                        .disabled(librarySelection==nil || tuningDraft.isDirty)
                    Button("Delete saved copy") {
                        pendingLibraryDelete=presetLibrary.entries.first(where:{$0.id==librarySelection})
                        confirmLibraryDelete=pendingLibraryDelete != nil
                    }.disabled(librarySelection==nil)
                }
                Text("\(presetLibrary.entries.count) / \(PerformanceGroupPresetLibrary.maximumEntries) presets · 256 KiB total archive limit")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Group layouts only. Device assignments and MPE tuning files are separate.")
                    .font(.caption).foregroundStyle(.secondary)
                if !libraryMessage.isEmpty { Text(libraryMessage).font(.caption) }
            }.padding(6)
        }.disabled(!didLoad || readFailed || !libraryLoaded || libraryReadFailed || editingLocked || studio.patchRunning)
        .onChange(of:librarySelection) { _ in renamePresetName="" }
        .confirmationDialog("Update selected preset?",isPresented:$confirmLibraryUpdate,titleVisibility:.visible) {
            Button("Update saved copy",role:.destructive) {
                defer { pendingLibraryUpdate=nil;pendingLibraryUpdateProfile=nil }
                guard let entry=pendingLibraryUpdate,let draft=pendingLibraryUpdateProfile,
                      profile==draft,!tuningDraft.isDirty,librarySelection==entry.id else {
                    libraryMessage="Selection or draft changed. Review again."
                    return
                }
                var next=presetLibrary
                guard next.update(expected:entry,name:entry.name,profile:draft),
                      storePresetLibrary(next) else {
                    libraryMessage="Update refused. Existing preset retained."
                    return
                }
                libraryMessage="Selected preset updated. Active saved layout unchanged."
            }
            Button("Cancel",role:.cancel) { pendingLibraryUpdate=nil;pendingLibraryUpdateProfile=nil }
        } message: {
            Text("Replace the selected personal preset with the current group draft. Factory presets and the active saved layout are not changed.")
        }
        .confirmationDialog("Delete saved preset copy?",isPresented:$confirmLibraryDelete,titleVisibility:.visible) {
            Button("Delete",role:.destructive) {
                defer { pendingLibraryDelete=nil }
                guard let entry=pendingLibraryDelete,presetLibrary.entries.contains(entry) else { return }
                var next=presetLibrary
                guard next.remove(entry.id),storePresetLibrary(next) else { return }
                if librarySelection==entry.id { librarySelection=next.entries.first?.id }
                libraryMessage="Saved copy deleted. Current draft and active saved layout unchanged."
            }
            Button("Cancel",role:.cancel) { pendingLibraryDelete=nil }
        } message: {
            Text(pendingLibraryDelete?.name ?? "Selected preset")
        }
    }

    private var starterPanel:some View {
        GroupBox("Ready to play · Instrument Groups") {
            VStack(alignment:.leading,spacing:8) {
                Picker("Choose a setup",selection:$starter) {
                    Section("One device / desktop") {
                        ForEach([PerformanceGroupStarterPreset.trackpadSolo,.mouseSolo,.desktopDuo,.xboxSolo,.phoneSolo]) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    Section("Party Jam") {
                        ForEach([PerformanceGroupStarterPreset.xboxDuo,.pocketJam,.mobileDuo,.mobileQuartet,.hybridBand]) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    Section("Optional hardware") {
                        ForEach([PerformanceGroupStarterPreset.cameraLead,.touchBarLead,.lidLead]) { p in
                            Text(p.title).tag(p)
                        }
                    }
                }
                Text(starter.detail).font(.callout)
                Text("Needs: " + starter.requiredSources.map(sourceLabel).joined(separator:", "))
                    .font(.caption).foregroundStyle(.secondary)
                if starter.isOptionalHardware {
                    Text("Requires compatible hardware and any necessary permission; availability is checked at Start.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if starter.requiresMobile {
                    Text(StudioController.groupRemoteStartEnabled
                         ? "Mobile pairing and explicit network consent are required before playing."
                         : "Mobile live Start is disabled in this build; preset can still be edited offline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(profile.groups.isEmpty ? "Load preset" : "Replace draft with preset") {
                        if profile.groups.isEmpty { loadStarter(starter,append:false) }
                        else {
                            pendingStarter=starter
                            pendingStarterDraft=profile
                            confirmStarterReplacement=true
                        }
                    }.buttonStyle(.borderedProminent)
                    if !profile.groups.isEmpty {
                        Button("Add preset to draft") { loadStarter(starter,append:true) }
                    }
                    Button("Manual / custom setup") { groupsExpanded=true }
                }
                HStack {
                    Button("Export group layout…") { exportGroupDraft() }
                        .disabled(!profile.isValid || profile.groups.isEmpty)
                    Button("Import group layout…") { importGroupDraft() }
                        .disabled(tuningDraft.isDirty)
                }
                Text("Choose → Load → Save groups → select devices → Start. Templates are editable copies. No automatic MIDI, haptic output, camera or network activation.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }.disabled(!didLoad || readFailed || editingLocked || studio.patchRunning)
        .confirmationDialog("Replace current group draft?",isPresented:$confirmStarterReplacement,titleVisibility:.visible) {
            Button("Replace draft",role:.destructive) {
                defer { pendingStarter=nil;pendingStarterDraft=nil }
                guard let preset=pendingStarter,pendingStarterDraft==profile else {
                    message="Draft changed. Choose a preset again.";return
                }
                loadStarter(preset,append:false)
            }
            Button("Cancel",role:.cancel) { pendingStarter=nil;pendingStarterDraft=nil }
        } message: {
            Text("This replaces the current unsaved group layout, not your saved profile. Revert remains available until you save.")
        }
    }

    private var draftControllerSources:Set<SensorSource> {
        Set(profile.groups.flatMap { $0.patch.routes.map(\.source) }).intersection(GamepadFrame.sources)
    }

    private var quickAssignment:[SensorSource:UUID]? {
        GamepadQuickAssignment.suggest(required:draftControllerSources,selected:studio.gamepadBindings,
                                      available:Set(studio.gamepadChoices.map(\.id)))
    }

    private var draftControllersReady:Bool {
        let ids=draftControllerSources.compactMap { studio.gamepadChoice(for:$0) }
        return ids.count==draftControllerSources.count && Set(ids).count==ids.count &&
            Set(ids).isSubset(of:Set(studio.gamepadChoices.map(\.id)))
    }

    private var quickReadiness:PerformanceGroupQuickReadiness {
        .init(profile:profile,selected:studio.gamepadBindings,
              available:Set(studio.gamepadChoices.map(\.id)),
              allowLayering:profile==saved && allowLayering,
              mobileEnabled:StudioController.groupRemoteStartEnabled)
    }

    private func readinessMessage(_ blocker:PerformanceGroupQuickReadiness.Blocker) -> String {
        switch blocker {
        case .invalidProfile: "Fix invalid group names or mappings."
        case .emptyProfile: "Load a preset or create a group with mappings."
        case .unsupportedMappings: "Review unsupported live mappings in advanced setup."
        case .portIdentityConflict: "Group port identities conflict. Review the layout."
        case .layeringNeedsConsent: "Shared inputs require explicit layering approval in advanced setup."
        case .mobileSetupRequired: "Mobile layout: save and complete trusted connection setup."
        case .mobileDisabled: "Mobile Start is disabled in this build."
        case .controllerMissing(let source): "Select a connected " + sourceLabel(source) + "."
        case .controllerDuplicate(let source): "Choose a distinct controller for " + sourceLabel(source) + "."
        }
    }

    private var quickSaveAndStart:Bool {
        didLoad && !readFailed && !editingLocked && !studio.patchRunning &&
        !tuningDraft.isDirty && tuningPreview == nil && hapticSelection.isEmpty &&
        profile != saved && quickReadiness.readyForLocalStart
    }

    private var quickPlayPanel:some View {
        GroupBox("Play / setup") {
            VStack(alignment:.leading,spacing:6) {
                Text(studio.groupGamepadStatus).font(.caption)
                if !studio.groupGamepadsRunning && didLoad && !readFailed {
                    if quickReadiness.readyForLocalStart {
                        Text("Layout and controller selections pass offline checks. Start still checks hardware and ports.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(quickReadiness.blockers.enumerated()),id:\.offset) { item in
                            Label(readinessMessage(item.element),systemImage:"info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !profile.groups.isEmpty {
                    Text(profile == saved ? "Saved layout" : "Unsaved layout · retained until app closes")
                        .font(.caption.weight(.semibold))
                    ForEach(profile.groups) { group in
                        VStack(alignment:.leading,spacing:2) {
                            Text(group.name).font(.callout)
                            Text(Set(group.patch.routes.map(\.source)).sorted { $0.rawValue < $1.rawValue }
                                .map(sourceLabel).joined(separator:", "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(group.plannedPortName).font(.caption2).textSelection(.enabled)
                        }
                    }
                }
                if !draftControllerSources.isEmpty && !studio.groupGamepadsRunning {
                    HStack {
                        Button("Refresh controllers") { studio.refreshBuilderGamepads() }
                        Button("Use available controller") {
                            guard let next=quickAssignment else { return }
                            for source in draftControllerSources {
                                studio.setGamepadChoice(next[source],for:source)
                            }
                            message="Controller selected. Review or change the assignment before Start."
                        }.disabled(quickAssignment == nil)
                    }.disabled(studio.patchRunning || !studio.groupCleanupIDs.isEmpty || studio.groupDisposalCount != 0)
                    ForEach(GamepadFrame.orderedSources.filter { draftControllerSources.contains($0) },id:\.self) { source in
                        Picker(GamepadFrame.slotLabel(source),selection:Binding<UUID?>(
                            get:{studio.gamepadChoice(for:source)},
                            set:{studio.setGamepadChoice($0,for:source)})) {
                            Text("Select controller").tag(UUID?.none)
                            ForEach(studio.gamepadChoices) { choice in
                                Text(choice.name).tag(Optional(choice.id))
                            }
                        }.disabled(studio.patchRunning || studio.groupGamepadsRunning)
                    }
                    if !draftControllersReady {
                        Text("Select a different connected controller for each required role. No ambiguous assignment is made.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Save groups") { save() }
                        .disabled(!didLoad || readFailed || editingLocked || studio.patchRunning || !profile.isValid || profile==saved)
                    if quickSaveAndStart {
                        Button("Save & Start standard MIDI") {
                            guard quickSaveAndStart,save() else { return }
                            startSavedGroups()
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Start standard MIDI") { startSavedGroups() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStartGroups || !quickReadiness.readyForLocalStart || studio.patchRunning || tuningPreview != nil || !hapticSelection.isEmpty)
                    }
                    Button("Stop / Release All") { studio.stopGroupGamepads() }
                        .disabled(!studio.groupGamepadsRunning)
                    Button("Device setup / advanced") { groupsExpanded=true }
                }
                if !studio.groupRegisteredIDs.isEmpty || !studio.groupCleanupIDs.isEmpty || studio.groupDisposalCount != 0 {
                    HStack {
                        Button("Close ports") { studio.closeGroupPorts() }
                            .disabled(studio.groupGamepadsRunning || studio.groupRegisteredIDs.isEmpty)
                        Button("Retry cleanup") { studio.retryGroupCleanup() }
                            .disabled(studio.groupGamepadsRunning ||
                                      (studio.groupCleanupIDs.isEmpty && studio.groupDisposalCount == 0))
                    }
                    Text("\(studio.groupRegisteredIDs.count) retained/registered ports · \(studio.groupCleanupIDs.count) pending MIDI cleanups · \(studio.groupDisposalCount) pending disposals")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if tuningDraft.isDirty || tuningPreview != nil || !hapticSelection.isEmpty {
                    Text("Advanced tuning or Trackpad output selected. Review in Device setup / advanced before Start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if profile.groups.contains(where:{ $0.patch.routes.contains(where:{ $0.source.isGroupRemote }) }) {
                    Button("Mobile pairing and Start") { groupsExpanded=true }
                    Text("Save first, then use the mobile connection controls. Network consent remains explicit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !groupsExpanded && !message.isEmpty { Text(message).font(.caption) }
                Text("Standard MIDI needs a DAW instrument on each group port. This is not an automatic audio or Trackpad-output mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            starterPanel
            userPresetPanel
            quickPlayPanel
            DisclosureGroup("Performance Studio - Instrument Groups (experimental)",isExpanded:$groupsExpanded) {
            VStack(alignment:.leading,spacing:10) {
                Text("Organize note and Helper mappings into named groups. Experimental live group MIDI supports saved Xbox, Trackpad, Magic Mouse, Touch Bar ribbon, lid and single-hand camera Helper profiles. Mobile groups and MPE require their separate experimental build gates.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add empty group") { add(patch:.init()) }
                    Button("Add from Builder draft") { add(patch:currentPatch) }
                        .disabled(!currentPatch.isValid || currentPatch.routes.isEmpty)
                }.disabled(editingLocked || !didLoad || readFailed || !profile.isValid || profile.groups.count >= PerformanceGroupProfile.maximumGroups)
                Text("Edit group names and mobile mappings directly, or edit a copy in Builder and replace the selected group's mappings. Existing port identities are preserved when editing.")
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
                    Text("Unsaved changes. Draft retained while the app is open; save before quitting.").font(.caption).foregroundStyle(.orange)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if didLoad && !readFailed {
                    PerformanceGroupTuningPreviewView(profile:saved,locked:editingLocked || profile != saved,configuration:$tuningPreview,draft:$tuningDraft)
                    DynamicMPEPreviewView(profile:saved,locked:editingLocked || profile != saved,preview:$dynamicPreview)
                }
                liveControls
            }.padding(6)
            }
        }.onAppear { load(); loadPresetLibrary() }
        .onChange(of:profile) { _ in rememberGroupDraft() }
        .onDisappear { rememberGroupDraft() }
        .onChange(of:studio.groupGamepadsRunning) { running in
            if !running { hapticSelection = [] }
        }
         .confirmationDialog("Load and replace group draft?",isPresented:$confirmImport,titleVisibility:.visible) {
            Button("Replace draft",role:.destructive) {
                defer { pendingImport=nil;pendingImportDraft=nil }
                guard let imported=pendingImport,pendingImportDraft==profile else {
                    message="Draft changed. Import again.";return
                }
                applyImportedGroupDraft(imported)
            }
            Button("Cancel",role:.cancel) { pendingImport=nil;pendingImportDraft=nil }
        } message: {
            Text("The loaded layout keeps its original group port identities. Your saved profile remains unchanged until Save groups. Device assignments and tuning are not loaded.")
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
                      snapshot.layering == allowLayering,snapshot.tuning == tuningPreview,
                      snapshot.deviceConsent == currentTunedConsent else {
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
