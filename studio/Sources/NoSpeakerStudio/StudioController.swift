#if os(macOS)
import Foundation
import SwiftUI
import AVFoundation
import NoSpeakerCore
import NoSpeakerMac

struct ActiveMIDINote: Identifiable, Equatable {
    var id: String { "\(channel)-\(note)" }
    var channel: Int
    var note: Int
    var velocity: Int
}

private enum ChordMPEConfigurationError: LocalizedError {
    case delivery
    var errorDescription: String? { "Could not configure the dedicated MPE output. Check CoreMIDI and re-arm." }
}

@MainActor
final class StudioController: ObservableObject {
    @Published var engineStatus = "Initializing haptic engine…"
    @Published var engineReady = false
    @Published var lastError: String?
    @Published var isPlaying = false
    @Published var masterLevel = 0.75 {
        didSet {
            updateChordHaptics(); updateTouchBarHaptics(); updateGamepadHaptics(force:true)
            // Gain must also follow the master slider while the Touch view
            // is not mounted. Keep the armed mapping and note ownership.
            if touchRunning || instrumentPreviewRequested {
                var updated = currentTouchConfiguration
                updated.masterLevel = masterLevel
                updateTouchConfiguration(updated)
            }
            groupHost.discardGroupHapticAttacks()
            updateGroupHaptics()
        }
    }
    @Published var bpm = 120.0
    @Published private(set) var instrumentPatch = StudioController.readInstrumentPatch()
    private var builderDraftSession = BuilderDraftSession()
    @Published private(set) var patchRunning = false
    @Published private(set) var patchInputs: [PatchSimulation.Input] = []
    @Published private(set) var patchMessages: [String] = []
    private var patchMonitorBuffer = BuilderCommandMonitor.Buffer()
    private var builderPerformanceMetrics = BuilderPerformanceMetrics()
    @Published private(set) var patchStatus = "Builder idle"
    private var patchSimulation = PatchSimulation()
    private var debugCameraRunToken:UUID?
    var patchDebugCameraRunID:UUID? { patchRunning ? debugCameraRunToken : nil }
    private var patchLedger = PatchOutputLedger()
    private var ensembleTake:EnsembleTake?
    private var ensembleTakeTimeout:Task<Void,Never>?
    private var ensembleTakeToken:UUID?
    @Published var ensembleRecordNext = false
    @Published var ensembleRecordBPM = 120.0
    @Published private(set) var ensembleRecording = false
    @Published private(set) var ensembleTakeReady = false
    @Published private(set) var ensembleTakeStatus = "No take recorded"

    private func beginEnsembleTakeIfArmed() {
        guard ensembleRecordNext else { return }
        ensembleRecordNext = false
        guard let take = EnsembleTake(patch:instrumentPatch,bpm:ensembleRecordBPM,now:ProcessInfo.processInfo.systemUptime,tuning:airTunedPlan) else {
            ensembleTakeStatus = "Recording could not be armed for this patch"
            return
        }
        ensembleTake = take
        ensembleRecording = true
        ensembleTakeReady = false
        ensembleTakeStatus = take.isTuned ? "Recording tuned Air MPE" : "Recording reconciled Builder commands"
        let token = UUID()
        ensembleTakeToken = token
        ensembleTakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(EnsembleTake.maximumDuration)) } catch { return }
            guard let self,self.ensembleTakeToken == token,self.ensembleRecording,!Task.isCancelled else { return }
            self.ensembleTake?.interrupt(now:ProcessInfo.processInfo.systemUptime)
            self.updateEnsembleTakeState()
        }
    }

    private func updateEnsembleTakeState() {
        guard let take = ensembleTake, take.endTick != nil else { return }
        ensembleTakeToken = nil
        ensembleTakeTimeout?.cancel()
        ensembleTakeTimeout = nil
        ensembleRecording = false
        ensembleTakeReady = !take.events.isEmpty
        ensembleTakeStatus = (take.isTuned ? "MPE · " : "") + "\(take.events.count) events · " + (take.truncated ? "bounded partial take" : "take finished")
    }

    func stopEnsembleTake() {
        guard ensembleRecording else { return }
        ensembleTake?.finish(now:ProcessInfo.processInfo.systemUptime)
        updateEnsembleTakeState()
    }

    func discardEnsembleTake() {
        guard !ensembleRecording else { return }
        ensembleTake = nil; ensembleTakeReady = false; ensembleTakeStatus = "No take recorded"
    }

    func exportEnsembleTake() throws -> Data {
        guard !ensembleRecording,let take = ensembleTake else { throw MIDIClipError.empty }
        return try take.encoded()
    }
    private let builderGamepads = BuilderGamepadSource()
    private var gamepadHaptics: LiveNoteHapticOutput?
    private var gamepadHapticToken: UUID?
    private var gamepadHapticVoices = GamepadHapticVoices()
    private var lastGamepadHapticFrame: HapticFrame?
    @Published private(set) var patchHapticEnabled = false
    @Published private(set) var patchGamepadOutputSelection: GamepadOutputSelection?
    private var gamepadOutputPlan: GamepadOutputPlan?

    private func updateGamepadHaptics(force:Bool = false,attack:Bool = false) {
        guard let gamepadHaptics else { return }
        let frame = gamepadHapticVoices.frame()
        guard force || attack || frame != lastGamepadHapticFrame else { return }
        lastGamepadHapticFrame = frame
        gamepadHaptics.update(frame:frame,masterLevel:masterLevel,attack:attack)
    }
    @Published private(set) var gamepadChoices:[BuilderGamepadSource.Choice] = []
    @Published var gamepadSlot1:UUID?
    @Published var gamepadSlot2:UUID?
    @Published var gamepadSlot3:UUID?
    @Published var gamepadSlot4:UUID?
    func gamepadChoice(for source:SensorSource) -> UUID? {
        switch source {
        case .gamepad1: return gamepadSlot1
        case .gamepad2: return gamepadSlot2
        case .gamepad3: return gamepadSlot3
        case .gamepad4: return gamepadSlot4
        default: return nil
        }
    }
    func setGamepadChoice(_ choice:UUID?,for source:SensorSource) {
        guard !patchRunning, !groupGamepadsRunning else { return }
        switch source {
        case .gamepad1: gamepadSlot1 = choice
        case .gamepad2: gamepadSlot2 = choice
        case .gamepad3: gamepadSlot3 = choice
        case .gamepad4: gamepadSlot4 = choice
        default: break
        }
    }
    var gamepadBindings: [SensorSource:UUID] {
        var result: [SensorSource:UUID] = [:]
        for source in GamepadFrame.orderedSources { result[source] = gamepadChoice(for:source) }
        return result
    }
    func refreshBuilderGamepads() {
        guard !patchRunning, !groupGamepadsRunning else { return }
        gamepadChoices = builderGamepads.refresh()
        for source in GamepadFrame.orderedSources {
            if let choice = gamepadChoice(for:source), !gamepadChoices.contains(where:{ $0.id == choice }) {
                setGamepadChoice(nil,for:source)
            }
        }
    }
    // Experimental group mode shares the one BuilderGamepadSource. No
    // controller handlers or MIDI ports are acquired before explicit Start.
    @Published private(set) var groupGamepadsRunning = false
    @Published private(set) var groupGamepadStatus = "Group MIDI idle"
    @Published private(set) var groupRegisteredIDs: Set<UUID> = []
    @Published private(set) var groupCleanupIDs: Set<UUID> = []
    @Published private(set) var groupDisposalCount = 0
    @Published private(set) var groupFaultIDs: Set<UUID> = []
    @Published private(set) var groupStoppedIDs: Set<UUID> = []
    @Published private(set) var groupSourceStates: [SensorSource:PerformanceGroupGamepadSession.SourceState] = [:]
    private var groupGamepadTokens: [SensorSource:UUID] = [:]
    private var groupSurfaceMailbox: PatchSurfaceMailbox?
    private var groupHinge: MacBookHingeAngleSource?
    private var groupCamera: BuilderCameraSource?
    private var groupCameraLastFrame = 0.0
    private var groupCameraReceivedFrame = false
    private var groupCameraOrientation: AirControlOrientation = .upright
    private var groupCameraMirrorX = false
    private var groupNativeBar = false
    private var groupSurfaceOrientation: SurfaceOrientation = .horizontal
    private var groupRunToken: UUID?
    private var groupWatchdog: Task<Void,Never>?
    private var groupHaptics:LiveNoteHapticOutput?
    private var groupHapticToken:UUID?
    @Published private(set) var groupHapticStatus = "Group Trackpad output off"
    @Published private(set) var groupHapticRunning = false
    private var groupTimingAccumulator = PerformanceGroupTimingDiagnostics()
    private var groupTimingLastPublished = 0.0
    @Published private(set) var groupTiming = PerformanceGroupTimingDiagnostics()
    private var groupHost: PerformanceGroupMIDIHost { .shared }
    private var groupRemoteTransport: RemoteLoopbackTransport?
    private var groupRemotePage: RemoteLoopbackPageServer?
    private var groupRemoteRunID: UUID?
    @Published private(set) var groupRemoteReady = false
    @Published private(set) var groupRemoteSlots: [UUID:SensorSource] = [:]
    @Published private(set) var groupRemoteEndpoint: RemoteEndpoint?
    @Published private(set) var groupRemoteStatus = "Mobile listener off"

    static var groupRemoteStartEnabled: Bool {
        #if TIHULU_GROUP_REMOTE_LIVE
        true
        #else
        false
        #endif
    }

    private func refreshGroupOutputState() {
        let registered = groupHost.registeredIDs
        let cleanup = groupHost.pendingCleanup
        let disposal = groupHost.pendingDisposalCount
        if registered != groupRegisteredIDs { groupRegisteredIDs = registered }
        if cleanup != groupCleanupIDs { groupCleanupIDs = cleanup }
        if disposal != groupDisposalCount { groupDisposalCount = disposal }
        let states = groupHost.localSourceStates
        if states != groupSourceStates { groupSourceStates = states }
    }

    // Native and physical acceptance must explicitly enable this experimental
    // compile-time switch. Default and stable builds never activate tuned MIDI.
    static var groupMPEStartEnabled: Bool {
        #if TIHULU_GROUP_MPE_LIVE
        true
        #else
        false
        #endif
    }

    static var groupHapticStartEnabled:Bool {
        #if TIHULU_GROUP_HAPTIC_LIVE
        true
        #else
        false
        #endif
    }

    static var groupTunedHapticStartEnabled:Bool {
        #if TIHULU_GROUP_MPE_HAPTIC_LIVE
        return groupHapticStartEnabled && groupMPEStartEnabled
        #else
        return false
        #endif
    }

    @Published private(set) var groupTunedConfiguration: PerformanceGroupTuningConfiguration?
    @Published private(set) var groupDynamicPreview:DynamicMPEPreview?
    @Published private(set) var groupCapacityRefusals = 0
    var groupRetainsTuning:Bool { groupTunedConfiguration != nil || groupDynamicPreview != nil }

    func startGroupGamepads(profile: PerformanceGroupProfile, allowLayering: Bool,
                            tuning: PerformanceGroupTuningConfiguration? = nil,
                            confirmedTuning: Bool = false,
                            remoteTransport:RemoteLoopbackTransport? = nil,
                            remotePage:RemoteLoopbackPageServer? = nil,
                            confirmedLAN:Bool = false,hapticGroups:Set<UUID> = [],
                            dynamicPreview:DynamicMPEPreview? = nil,confirmedDynamic:Bool = false) {
        guard (dynamicPreview != nil) == confirmedDynamic,
              dynamicPreview == nil || (PerformanceGroupMIDIHost.dynamicMPEEnabled && tuning == nil &&
                remoteTransport == nil && remotePage == nil &&
                (hapticGroups.isEmpty || PerformanceGroupMIDIHost.dynamicMPEHapticsEnabled) && !confirmedTuning && !confirmedLAN) else {
            groupGamepadStatus = "Dynamic MPE requires a separately enabled, confirmed local start."
            return
        }
        guard hapticGroups.isEmpty || (Self.groupHapticStartEnabled &&
                (tuning == nil || (Self.groupTunedHapticStartEnabled && confirmedTuning && remoteTransport == nil))) else {
            groupGamepadStatus = "Group Trackpad output requires an enabled standard or explicitly confirmed local MPE start."
            return
        }
        let remoteEnabled = remoteTransport != nil
        guard remoteEnabled == (remotePage != nil),
              !remoteEnabled || Self.groupRemoteStartEnabled else {
            groupGamepadStatus = "Mobile group transport is disabled or incomplete."
            return
        }
        if let transport = remoteTransport, let page = remotePage {
            guard page.groupNeutralHandshake,transport.endpoint == page.endpoint,
                  transport.endpoint.isLoopback ||
                    (confirmedLAN && remoteLoopbackVerified &&
                     RemoteLANChoice.available().contains(where:{ $0.endpoint == transport.endpoint })) else {
                groupGamepadStatus = "Remote endpoint or trusted LAN confirmation is invalid."
                return
            }
        }
        guard tuning == nil || Self.groupMPEStartEnabled else {
            groupGamepadStatus = "Live MPE is disabled in this build; use the offline preview."
            return
        }
        guard !groupRetainsTuning else {
            groupGamepadStatus = "Close the retained tuned ports before any new group performance."
            return
        }
        guard !patchRunning, !groupGamepadsRunning, !midiRunning, !midiHelperRunning,
              !touchRunning, !sequenceRunning, !chordArmed, !touchBarOutputArmed,
              !isPlaying, !speakerBusy, !liveHingeEnabled, !captureArmed, !pointerCaptured,
              !liveNoteOwnsHaptics,!sequenceOwnsHaptics else {
            groupGamepadStatus = "Stop other live performances and Builder before starting group MIDI."
            return
        }
        let specifications:[UUID:PerformanceGroupTuningPlan.Specification]
        do {
            if let dynamicPreview {
                guard dynamicPreview.profile == profile else { throw DynamicMPEActivationPlan.AdmissionError.unsupportedProfile }
                let plan = try DynamicMPEActivationPlan(profile:profile,tuning:dynamicPreview.tuning,
                    confirmed:confirmedDynamic,allowLayering:allowLayering,registeredIDs:groupHost.registeredIDs,
                    cleanupIDs:groupHost.pendingCleanup,pendingDisposalCount:groupHost.pendingDisposalCount,
                    allowSurfaces:true,allowScalars:true,allowCamera:true,hapticGroups:hapticGroups,
                    allowDynamicHaptics:PerformanceGroupMIDIHost.dynamicMPEHapticsEnabled)
                specifications = plan.preview.tuning
            } else {
                let activation = try PerformanceGroupActivationPlan(profile:profile,mode:tuning.map { .tuned($0) } ?? .standard,
                    allowLayering:allowLayering,confirmedTuning:confirmedTuning,
                    registeredIDs:groupHost.registeredIDs,cleanupIDs:groupHost.pendingCleanup,
                    pendingDisposalCount:groupHost.pendingDisposalCount,allowRemote:remoteEnabled)
                specifications = activation.tuning
            }
        } catch {
            groupGamepadStatus = "Group Start rejected: " + String(describing:error)
            return
        }
        let routes = profile.groups.flatMap { $0.patch.routes }
        let sources = Set(routes.map(\.source))
        if sources.contains(.camera) {
            if let retiringPatchCamera, !retiringPatchCamera.isStopped {
                groupGamepadStatus = "Previous camera is stopping. Restart after release."
                return
            }
            retiringPatchCamera = nil
            switch BuilderCameraSource.authorization {
            case .authorized: break
            case .notDetermined:
                groupGamepadStatus = "Grant camera permission, then explicitly Start again."
                AVCaptureDevice.requestAccess(for:.video) { _ in }
                return
            default:
                groupGamepadStatus = "Camera permission denied or restricted. Check System Settings."
                return
            }
        }
        cancelStartupGreeting()
        let needsSurface = sources.contains(.trackpad) || sources.contains(.magicMouse)
        if !hapticGroups.isEmpty {
            let projection:PerformanceGroupHapticProjection?
            if let dynamicPreview {
                projection = try? .init(preparedDynamic:dynamicPreview,selected:hapticGroups)
            } else if specifications.isEmpty {
                projection = try? .init(profile:profile,selected:hapticGroups)
            } else {
                projection = try? .init(profile:profile,selected:hapticGroups,preparedTuning:specifications)
            }
            guard projection != nil,requireEngine(),driver != nil else {
                groupGamepadStatus = "Selected group Trackpad output unavailable; Start refused."
                return
            }
            renderGeneration &+= 1
            playback?.stop(closeDriver:false)
        }
        if needsSurface {
            guard requireEngine(), touch != nil else {
                groupGamepadStatus = "Native surface monitoring unavailable on this Mac."
                return
            }
        }
        guard releaseBuilderOutput() else {
            groupGamepadStatus = "Builder MIDI cleanup remains pending. Retry Builder Stop."
            return
        }
        guard builderGamepads.bind(required:sources,choices:gamepadBindings) else {
            groupGamepadStatus = "Select distinct connected controllers for every mapped slot."
            return
        }
        do {
            try groupHost.startGamepads(profile:profile,allowLayering:allowLayering,
                allowSurfaces:true,allowScalars:true,allowCamera:true,tuning:specifications,allowRemote:remoteEnabled,hapticGroups:hapticGroups,
                allowTunedHaptics:Self.groupTunedHapticStartEnabled && confirmedTuning,
                dynamicMPE:dynamicPreview != nil,confirmedDynamicMPE:confirmedDynamic)
            groupTunedConfiguration = tuning
            groupDynamicPreview = dynamicPreview
        } catch {
            builderGamepads.stop()
            refreshGroupOutputState()
            // Preserve the requested mode while any partially opened endpoints
            // or cleanup debt remain. Do not advertise successful MPE setup.
            if !specifications.isEmpty, !groupRegisteredIDs.isEmpty || !groupCleanupIDs.isEmpty || groupDisposalCount != 0 {
                groupTunedConfiguration = tuning
                groupDynamicPreview = dynamicPreview
            }
            groupGamepadStatus = "Group setup failed: " + String(describing:error) + ". No fallback; check cleanup and close ports."
            return
        }
        let token = UUID()
        groupRunToken = token
        groupTimingAccumulator = .init()
        groupTiming = .init()
        groupTimingLastPublished = ProcessInfo.processInfo.systemUptime
        groupGamepadsRunning = true
        groupFaultIDs = []
        groupStoppedIDs = []
        groupCapacityRefusals = 0
        refreshGroupOutputState()
        do {
            for source in sources.subtracting(Set(SensorSource.groupRemoteSources)).sorted(by:{ $0.rawValue < $1.rawValue }) {
                groupGamepadTokens[source] = try groupHost.bindGamepad(source,now:ProcessInfo.processInfo.systemUptime)
            }
        } catch {
            stopGroupGamepads()
            groupGamepadStatus = "Controller binding failed; group output stopped. Check cleanup status."
            return
        }
        if needsSurface {
            let mailbox = PatchSurfaceMailbox(excludedSurface:nil)
            groupSurfaceOrientation = magicMouseOrientation
            groupSurfaceMailbox = mailbox
            touch?.setPatchMailbox(mailbox)
            refreshSharedSurfaceMonitoring()
            guard touchPreviewRunning else {
                stopGroupGamepads()
                groupGamepadStatus = "Surface monitoring could not start; group output stopped."
                return
            }
            if let message = missingNativeSurfaceMessage(nativeSurfaces(for:Set(sources))) {
                stopGroupGamepads()
                groupGamepadStatus = message
                return
            }
        }
        if sources.contains(.touchBar) {
            groupNativeBar = true
            installTouchBar()
        }
        if sources.contains(.lid) {
            let sensor = MacBookHingeAngleSource()
            groupHinge = sensor
            sensor.onAngle = { [weak self, weak sensor] degrees,receipt in
                guard let self, let sensor, self.groupHinge === sensor, self.groupRunToken == token else { return }
                self.receiveGroupScalar(.lid,value:PhysicalPatchRuntime.normalizedLid(degrees),run:token,hostTime:receipt)
            }
            sensor.onLoss = { [weak self, weak sensor] reason in
                guard let self, let sensor, self.groupHinge === sensor, self.groupRunToken == token else { return }
                self.groupHinge = nil
                self.retireGroupSource(.lid,reason:reason,run:token)
            }
            let started = sensor.start()
            guard groupRunToken == token else { sensor.stop(); return }
            if !started {
                let reason = sensor.status
                stopGroupGamepads()
                groupGamepadStatus = "Lid input could not start: " + reason
                return
            }
        }
        if sources.contains(.camera) {
            let camera = BuilderCameraSource()
            groupCamera = camera
            groupCameraLastFrame = ProcessInfo.processInfo.systemUptime
            groupCameraReceivedFrame = false
            groupCameraOrientation = patchCameraOrientation
            groupCameraMirrorX = patchCameraMirrorX
            camera.start(deviceID:patchCameraDeviceID)
        }
        if let transport = remoteTransport, let page = remotePage {
            do {
                groupRemoteRunID = try groupHost.beginRemoteGroupBridge()
                groupRemoteTransport = transport
                groupRemotePage = page
                groupRemoteEndpoint = transport.endpoint
                groupRemoteReady = false
                groupRemoteSlots = [:]
                groupRemoteStatus = "Starting TLS controller"
                transport.start()
                page.start()
            } catch {
                stopGroupGamepads()
                groupGamepadStatus = "Mobile bridge setup failed; all group output released."
                return
            }
        }
        refreshGroupOutputState()
        groupGamepadStatus = dynamicPreview != nil
            ? "Dynamic MPE pool setup sent; receiver not verified. Neutralize controls before playing."
            : tuning == nil
            ? "Standard group ports registered. Release controller controls and lift each touch surface before playing."
            : "MPE setup sent; receiver not verified. Release controller controls and lift each touch surface before playing."
        if !hapticGroups.isEmpty {
            guard startGroupHaptics(run:token) else {
                stopGroupGamepads()
                groupGamepadStatus = "Requested Trackpad output could not start. Group Start aborted."
                return
            }
        }
        pollGroupGamepads(run:token)
        guard groupRunToken == token else { return }
        builderGamepads.beginEventsWithReceipt { [weak self] source,frame,receipt in
            self?.receiveGroupGamepad(source:source,frame:frame,run:token,hostTime:receipt)
        }
        groupWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(20)) } catch { return }
                guard let self, self.groupRunToken == token else { return }
                let cycleStarted = ProcessInfo.processInfo.systemUptime
                // Drain known remote disconnects together with expiry before
                // any local samples can reconcile shared continuous targets.
                if self.groupRemoteRunID != nil { self.drainGroupRemote(run:token) }
                guard self.groupRunToken == token else { return }
                self.consumeGroupReports(self.groupHost.expireGamepads(now:ProcessInfo.processInfo.systemUptime))
                guard self.groupRunToken == token else { return }
                self.drainGroupSurfaces(run:token)
                guard self.groupRunToken == token else { return }
                self.drainGroupCamera(run:token)
                self.pollGroupGamepads(run:token)
                guard self.groupRunToken == token else { return }
                let end = ProcessInfo.processInfo.systemUptime
                self.updateGroupHaptics()
                self.groupTimingAccumulator.record(start:cycleStarted,end:ProcessInfo.processInfo.systemUptime)
                if end-self.groupTimingLastPublished >= 1 {
                    self.groupTimingLastPublished = end
                    self.groupTiming = self.groupTimingAccumulator
                }
            }
        }
    }

    private func startGroupHaptics(run:UUID) -> Bool {
        guard groupRunToken == run,groupHaptics == nil,let driver else { return false }
        let token = UUID()
        let output = LiveNoteHapticOutput(driver:driver,requiresFreshGroupFrames:true)
        groupHaptics = output
        groupHapticToken = token
        do {
            try output.start { [weak self] message in
                Task { @MainActor in
                    guard let self,self.groupRunToken == run,self.groupHapticToken == token else { return }
                    self.stopGroupHaptics(reason:"Trackpad output stopped: " + message)
                }
            }
            groupHapticRunning = true
            groupHapticStatus = "Experimental group Trackpad output active; MIDI remains separate."
            updateGroupHaptics()
            return true
        } catch {
            stopGroupHaptics(reason:"Trackpad output could not start.")
            return false
        }
    }

    private func updateGroupHaptics() {
        guard let output = groupHaptics,let snapshot = groupHost.groupHapticSnapshot(now:ProcessInfo.processInfo.systemUptime) else { return }
        output.updateGroup(snapshot:snapshot,masterLevel:masterLevel)
    }

    func stopGroupHaptics(reason:String = "Group Trackpad output off; MIDI unchanged") {
        groupHapticToken = nil
        groupHost.disableGroupHaptics()
        groupHaptics?.stop()
        groupHaptics = nil
        groupHapticRunning = false
        groupHapticStatus = reason
    }

    private func consumeGroupReports(_ reports: [PerformanceGroupDelivery.Report],reason:String? = nil) {
        for report in reports where report.capacityRefused > 0 {
            groupCapacityRefusals += min(report.capacityRefused,Int.max-groupCapacityRefusals)
        }
        let failures = reports.reduce(into:Set<UUID>()) { $0.formUnion($1.failedGroups) }
        if !failures.isEmpty {
            groupFaultIDs.formUnion(failures)
            groupStoppedIDs.formUnion(failures)
        }
        let faultNotice=PerformanceGroupDelivery.faultNotice(reports)
        if let faultNotice { groupGamepadStatus = faultNotice }
        // Publish reconciled edges promptly, not just on the next 20 ms
        // watchdog. The independent latest-frame mailbox never waits for
        // the physical driver. Silent polling does not do extra rendering.
        if !reports.isEmpty {
            updateGroupHaptics()
        }
        refreshGroupOutputState()
        if let reason {
            groupGamepadStatus = PerformanceGroupDelivery.eventNotice(reason:reason,reports:reports,
                hasPending:!groupCleanupIDs.isEmpty || groupDisposalCount != 0)
        }
        if groupGamepadsRunning, !groupRegisteredIDs.isEmpty,
           groupRegisteredIDs.isSubset(of:groupStoppedIDs) {
            stopGroupGamepads(after:reports,reason:reason)
        }
    }

    /// Sample the complete set of mapped Xbox slots before sending MIDI.
    /// Known simultaneous losses must reconcile once, before surviving
    /// snapshots. Event callbacks still provide immediate individual edges.
    private func pollGroupGamepads(run:UUID) {
        guard groupRunToken == run else { return }
        var snapshots:[(SensorSource,GamepadFrame,Double)] = []
        var departing:[SensorSource:UUID] = [:]
        for source in GamepadFrame.orderedSources {
            guard let token = groupGamepadTokens[source] else { continue }
            let receipt = ProcessInfo.processInfo.systemUptime
            if let frame = builderGamepads.read(source) { snapshots.append((source,frame,receipt)) }
            else { departing[source] = token }
        }
        if !departing.isEmpty {
            for source in departing.keys { groupGamepadTokens.removeValue(forKey:source) }
            let reports=groupHost.unbindGroupSources(departing)
            let reason="Controller input lost. Affected slots released; restart to rebind."
            consumeGroupReports(reports,reason:reason)
            guard groupRunToken == run else { return }
            if groupGamepadTokens.isEmpty && groupRemoteRunID == nil {
                stopGroupGamepads(after:reports,reason:reason); return
            }
        }
        for (source,frame,receipt) in snapshots {
            guard groupRunToken == run else { return }
            receiveGroupGamepad(source:source,frame:frame,run:run,hostTime:receipt)
        }
    }

    private func receiveGroupGamepad(source:SensorSource,frame:GamepadFrame?,run:UUID,hostTime:Double? = nil) {
        guard groupRunToken == run, let token = groupGamepadTokens[source] else { return }
        guard let frame else {
            groupGamepadTokens.removeValue(forKey:source)
            let reports=groupHost.unbindGamepad(source,token:token)
            let reason="Controller input lost. Stop and explicitly restart to bind a replacement."
            consumeGroupReports(reports,reason:reason)
            if groupGamepadTokens.isEmpty && groupRemoteRunID == nil { stopGroupGamepads(after:reports,reason:reason) }
            return
        }
        if let result = groupHost.receiveGamepad(source,token:token,frame:frame,
                                                  now:ProcessInfo.processInfo.systemUptime,hostTime:hostTime) {
            consumeGroupReports(result.reports)
        }
    }

    private func receiveGroupScalar(_ source:SensorSource,value:Double?,run:UUID,hostTime:Double? = nil) {
        guard groupRunToken == run, let token = groupGamepadTokens[source] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let result = groupHost.receiveScalar(source,token:token,value:value,hostTime:hostTime ?? now,now:now) else { return }
        consumeGroupReports(result.reports)
        if source == .lid, result.status == .lost || result.status == .waitingForNeutral {
            groupHinge?.stop()
            groupHinge = nil
            retireGroupSource(source,reason:"Lid input lost or stalled. Restart to rebind.",run:run)
        }
    }

    private func retireGroupSource(_ source:SensorSource,reason:String,run:UUID) {
        guard groupRunToken == run, let token = groupGamepadTokens.removeValue(forKey:source) else { return }
        let reports=groupHost.unbindGamepad(source,token:token)
        consumeGroupReports(reports,reason:reason)
        if groupGamepadTokens.isEmpty && groupRemoteRunID == nil { stopGroupGamepads(after:reports,reason:reason) }
    }

    private func stopGroupCamera(reason:String,run:UUID) {
        guard groupRunToken == run, let camera = groupCamera else { return }
        groupCamera = nil
        // Retire the source and release its MIDI before tearing down capture.
        retiringPatchCamera = camera
        retireGroupSource(.camera,reason:reason,run:run)
        camera.stop()
    }

    private func drainGroupCamera(run:UUID) {
        guard groupRunToken == run, let camera = groupCamera,
              let token = groupGamepadTokens[.camera] else { return }
        guard BuilderCameraSource.authorization == .authorized else {
            stopGroupCamera(reason:"Camera permission lost; restart explicitly.",run:run)
            return
        }
        for event in camera.drain() {
            guard groupRunToken == run, groupCamera === camera else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch event {
            case .ready:
                break
            case .fault(let reason):
                stopGroupCamera(reason:reason,run:run)
                return
            case .frame(let hand,let time):
                guard time.isFinite, time >= groupCameraLastFrame, now >= time,
                      now-time < PhysicalPatchRuntime.timeout else {
                    stopGroupCamera(reason:"Stale camera input; restart explicitly.",run:run)
                    return
                }
                groupCameraLastFrame = time
                groupCameraReceivedFrame = true
                let oriented = hand?.oriented(groupCameraOrientation,mirrorX:groupCameraMirrorX)
                if let result = groupHost.receiveCamera(token:token,hand:oriented,hostTime:time,now:now) {
                    consumeGroupReports(result.reports)
                }
            default:
                stopGroupCamera(reason:"Unexpected camera frame type; restart explicitly.",run:run)
                return
            }
        }
        guard groupRunToken == run, groupCamera === camera else { return }
        let limit = groupCameraReceivedFrame ? 2.0 : 8.0
        if ProcessInfo.processInfo.systemUptime-groupCameraLastFrame >= limit {
            stopGroupCamera(reason:"Camera stopped delivering fresh frames; restart explicitly.",run:run)
        }
    }

    /// Shared native queue overflow has unknown provenance; retire both
    /// surface owners atomically. A known bad sample retires only its source.
    /// Other devices and ports keep playing unless all sources are gone.
    private func retireGroupSurfaces(_ sources:Set<SensorSource>,reason:String,run:UUID) {
        guard groupRunToken == run else { return }
        var tokens:[SensorSource:UUID] = [:]
        for source in sources where source == .trackpad || source == .magicMouse {
            if let token = groupGamepadTokens.removeValue(forKey:source) { tokens[source] = token }
        }
        guard !tokens.isEmpty else { return }
        let reports=groupHost.unbindGroupSources(tokens)
        consumeGroupReports(reports,reason:reason)
        guard groupRunToken == run else { return }
        if groupGamepadTokens[.trackpad] == nil && groupGamepadTokens[.magicMouse] == nil,
           let mailbox = groupSurfaceMailbox {
            touch?.setPatchMailbox(nil)
            mailbox.close()
            groupSurfaceMailbox = nil
            refreshSharedSurfaceMonitoring()
        }
        if groupGamepadTokens.isEmpty && groupRemoteRunID == nil { stopGroupGamepads(after:reports,reason:reason) }
    }

    private func drainGroupSurfaces(run:UUID) {
        guard groupRunToken == run, let mailbox = groupSurfaceMailbox else { return }
        let batch = mailbox.drain()
        let now = ProcessInfo.processInfo.systemUptime
        // The original mailbox is bounded and edge-preserving. An overflow or
        // stale queued contact cannot be replayed as a new performance.
        if batch.overflow {
            retireGroupSurfaces([.trackpad,.magicMouse],reason:"Surface queue overflow. Surface owners released; restart to rebind. Other devices retained.",run:run)
            return
        }
        // Validate the entire batch before emitting any attack from a bad
        // source. A stale/unmapped sample from another device cannot stop it.
        var bad:Set<SensorSource> = []
        for sample in batch.samples {
            let source:SensorSource = sample.frame.surface == .trackpad ? .trackpad : .magicMouse
            guard groupGamepadTokens[source] != nil else { continue }
            if !PhysicalPatchRuntime.admitsPhysicalReceipt(sample.time,now:now) ||
               sample.frame.contacts.contains(where:{ $0.isDown && (!$0.x.isFinite || !$0.y.isFinite || !$0.size.isFinite) }) {
                bad.insert(source)
            }
        }
        if !bad.isEmpty {
            retireGroupSurfaces(bad,reason:"Stale or invalid surface input released. Restart affected surfaces explicitly.",run:run)
        }
        for sample in batch.samples {
            guard groupRunToken == run else { return }
            let source: SensorSource = sample.frame.surface == .trackpad ? .trackpad : .magicMouse
            guard let token = groupGamepadTokens[source] else { continue }
            // The earlier group sends may have blocked. Retire only this
            // expired surface; other devices and owners remain active.
            let admissionNow=ProcessInfo.processInfo.systemUptime
            guard PhysicalPatchRuntime.admitsPhysicalReceipt(sample.time,now:admissionNow) else {
                retireGroupSurfaces([source],reason:"Surface input expired during processing; restart affected surface explicitly.",run:run)
                continue
            }
            let contact = sample.frame.contacts.lazy.filter { $0.isDown }.min { $0.id < $1.id }
            var x: Double?
            var y: Double?
            var size: Double?
            if let contact {
                let rawX = min(1,max(0,Double(contact.x)))
                let rawY = min(1,max(0,Double(contact.y)))
                let point = source == .magicMouse ? groupSurfaceOrientation.transformed(x:rawX,y:rawY) : (rawX,rawY)
                x = point.0; y = point.1; size = min(1,max(0,Double(contact.size)))
            }
            if let result = groupHost.receiveSurface(source,token:token,x:x,y:y,size:size,
                                                    hostTime:sample.time,now:admissionNow) {
                consumeGroupReports(result.reports)
            }
        }
    }

    func groupRemoteLabelPreview(source:SensorSource) -> [String] {
        guard groupGamepadsRunning,groupRemoteReady,let run = groupRemoteRunID else { return [] }
        return groupHost.remoteGroupLabelPreview(run:run,source:source)
    }

    func issueGroupRemoteInvitation(source:SensorSource,shareLabels:Bool = false) throws -> Data {
        guard groupGamepadsRunning,groupRemoteReady,let run = groupRemoteRunID else {
            throw RemoteTouchError.unavailable
        }
        let secret = try RemoteLoopbackTransport.invitation()
        try groupHost.issueRemoteGroupInvitation(run:run,secret:secret,source:source,
                                                now:ProcessInfo.processInfo.systemUptime,shareLabels:shareLabels)
        return secret
    }

    func cancelGroupRemoteInvitation() {
        if let run = groupRemoteRunID { groupHost.cancelRemoteGroupInvitation(run:run) }
    }

    func revokeGroupRemote(_ connection:UUID) {
        guard let run = groupRemoteRunID,let transport = groupRemoteTransport else { return }
        let result = groupHost.revokeRemoteGroupConnection(run:run,connection:connection)
        transport.revoke(connection)
        groupRemoteSlots = groupHost.remoteGroupSlots(run:run)
        consumeGroupReports(result.reports)
    }

    private func detachGroupRemoteTransport(reason:String) {
        let transport = groupRemoteTransport
        let page = groupRemotePage
        groupRemoteRunID = nil
        groupRemoteTransport = nil
        groupRemotePage = nil
        groupRemoteReady = false
        groupRemoteSlots = [:]
        groupRemoteEndpoint = nil
        groupRemoteStatus = reason
        transport?.stop()
        page?.stop()
    }

    func stopGroupRemote() {
        guard let run = groupRemoteRunID else { return }
        let result = groupHost.stopRemoteGroupBridge(run:run)
        detachGroupRemoteTransport(reason:"Mobile listener stopped; local groups retained.")
        consumeGroupReports(result.reports)
        if groupGamepadsRunning && groupGamepadTokens.isEmpty { stopGroupGamepads() }
    }

    private func drainGroupRemote(run:UUID) {
        guard groupRunToken == run,let listener = groupRemoteRunID,
              let transport = groupRemoteTransport,let page = groupRemotePage else { return }
        switch page.status {
        case .failed,.stopped:
            stopGroupRemote()
            groupRemoteStatus = "HTTPS controller failed; remote owners released."
            return
        case .starting,.ready: break
        }
        let result = groupHost.processRemoteGroupEvents(run:listener,events:transport.drain(),
                                                        now:ProcessInfo.processInfo.systemUptime)
        consumeGroupReports(result.reports)
        guard groupRunToken == run,groupRemoteRunID == listener,groupRemoteTransport === transport else { return }
        if result.fault || result.actions.contains(.stop) {
            detachGroupRemoteTransport(reason:"Remote listener retired; remote owners released.")
            if groupGamepadTokens.isEmpty { stopGroupGamepads() }
            return
        }
        for action in result.actions {
            switch action {
            case .acknowledge(let id,let ok): transport.acknowledge(id,accepted:ok)
            case .capabilities(let id,let caps): transport.acknowledge(id,accepted:true,capabilities:caps)
            case .mapping(let id,let mapping): transport.acknowledge(id,accepted:true,mapping:mapping)
            case .mappingLabels(let id,let labels): transport.acknowledge(id,accepted:true,labels:labels)
            case .revoke(let id): transport.revoke(id)
            case .stop: break
            }
        }
        let ready = groupHost.remoteGroupReady(run:listener) && page.status == .ready
        let peers = groupHost.remoteGroupSlots(run:listener)
        if groupRemoteReady != ready { groupRemoteReady = ready }
        if groupRemoteSlots != peers { groupRemoteSlots = peers }
        let status = ready ? "TLS controller ready; receiver not verified." : "Waiting for TLS controller"
        if groupRemoteStatus != status { groupRemoteStatus = status }
    }

    func stopGroupGamepads() {
        stopGroupGamepads(after:[],reason:nil)
    }

    private func stopGroupGamepads(after previous:[PerformanceGroupDelivery.Report],reason:String?) {
        // Invalidate callbacks before stopping the existing adapter.
        guard groupGamepadsRunning else { return }
        groupRunToken = nil
        groupWatchdog?.cancel()
        groupWatchdog = nil
        groupTiming = groupTimingAccumulator
        groupGamepadTokens.removeAll()
        groupGamepadsRunning = false
        groupStoppedIDs = groupRegisteredIDs
        // Block new actuator frames before potentially slow MIDI cleanup.
        groupHaptics?.invalidateGroupFrames()
        // Release MIDI before potentially slow native monitor teardown.
        var reports=previous
        if let report = groupHost.panic() {
            reports.append(report)
            consumeGroupReports([report])
        }
        stopGroupHaptics(reason:"Group Trackpad output off")
        detachGroupRemoteTransport(reason:"Mobile listener off")
        builderGamepads.stop()
        groupHinge?.stop()
        groupHinge = nil
        if let camera = groupCamera {
            groupCamera = nil
            retiringPatchCamera = camera
            camera.stop()
        }
        if groupNativeBar {
            groupNativeBar = false
            installTouchBar()
        }
        if let mailbox = groupSurfaceMailbox {
            touch?.setPatchMailbox(nil)
            mailbox.close()
            groupSurfaceMailbox = nil
            refreshSharedSurfaceMonitoring()
        }
        let stopped = !groupRetainsTuning ? "Group MIDI stopped. Registered ports retained for restart." : "MPE stopped. Close retained ports before another Start."
        groupGamepadStatus = PerformanceGroupDelivery.eventNotice(reason:[reason,stopped].compactMap{$0}.joined(separator:" "),
            reports:reports,hasPending:!groupCleanupIDs.isEmpty || groupDisposalCount != 0)
    }

    func stopPerformanceGroup(_ id:UUID) {
        guard groupGamepadsRunning, groupRegisteredIDs.contains(id), !groupStoppedIDs.contains(id) else { return }
        if let report = groupHost.stopGroup(id) {
            groupStoppedIDs.insert(id)
            consumeGroupReports([report])
            updateGroupHaptics()
            if groupRegisteredIDs.isSubset(of:groupStoppedIDs) { stopGroupGamepads() }
        }
    }

    func retryGroupCleanup() {
        var reports:[PerformanceGroupDelivery.Report] = []
        // Snapshot the pending IDs; a newly discovered fault is reported,
        // not silently retried in the same user action.
        for id in groupHost.pendingCleanup.sorted(by:{ $0.uuidString < $1.uuidString }) {
            if let report = groupHost.retryCleanup(id) {
                reports.append(report)
                consumeGroupReports([report])
            }
        }
        _ = groupHost.retryDisposal()
        refreshGroupOutputState()
        if groupRegisteredIDs.isEmpty && groupCleanupIDs.isEmpty && groupDisposalCount == 0 && !groupGamepadsRunning {
            groupTunedConfiguration = nil
            groupDynamicPreview = nil
        }
        groupGamepadStatus = PerformanceGroupDelivery.cleanupNotice(reports,
            hasPending:!groupCleanupIDs.isEmpty || groupDisposalCount != 0)
    }

    func closeGroupPorts() {
        guard !groupGamepadsRunning else { return }
        let closed = groupHost.close()
        refreshGroupOutputState()
        if closed { groupTunedConfiguration = nil; groupDynamicPreview = nil }
        groupGamepadStatus = closed ? "Group MIDI ports closed." : "Group close refused or disposal failed; retry cleanup."
    }

    private let patchMIDI = ChordMIDIOutput(name: "TIHULU Instrument Builder")
    private let airTunedMIDI = ChordMIDIOutput(name:"TIHULU Air Strings MPE")
    private var airTunedPlan:AirTunedOutput?
    private var airTunedSelectors = MIDISelectorCleanup()
    @Published private(set) var patchTunedAirActive = false
    private func releaseBuilderOutput() -> Bool {
        let plan = airTunedPlan
        let notes = patchLedger.releaseAll(send:{ command in
            if let plan {
                guard let wire = plan.translate(command) else { return false }
                return airTunedMIDI.send(wire)
            }
            return patchMIDI.send(command)
        })
        let selectors = airTunedSelectors.releaseAll(send:{ airTunedMIDI.send($0) })
        if notes && selectors { airTunedPlan = nil }
        return notes && selectors
    }
    private let ensembleClockMIDI = ChordMIDIOutput(name:"TIHULU Ensemble Clock")
    private var ensembleClockTask:Task<Void,Never>?
    private var ensembleClockToken:UUID?
    private var ensembleClockStopDebt = false
    @Published private(set) var ensembleClockRunning = false
    @Published private(set) var ensembleClockBeat = 0
    @Published private(set) var ensembleClockStatus = "Clock idle"
    func startEnsembleClock(bpm:Double,beatsPerBar:Int,sendMIDI:Bool) {
        guard patchRunning,!ensembleClockRunning,!sendMIDI || patchMIDIEnabled,
              EnsembleClock(bpm:bpm,beatsPerBar:beatsPerBar,now:0) != nil else { return }
        guard clearEnsembleClockDebt() else { return }
        if sendMIDI {
            do { try ensembleClockMIDI.open() } catch { ensembleClockStatus = "Clock MIDI open failed"; return }
            // Even an uncertain Start delivery must be followed by Stop.
            ensembleClockStopDebt = true
            guard ensembleClockMIDI.sendRealtime(.start) else {
                stopEnsembleClock(reason:"Clock Start delivery failed")
                return
            }
        }
        // Setup and CoreMIDI open can take longer than a tick. Start the
        // absolute schedule only after successful transport preparation.
        guard var clock = EnsembleClock(bpm:bpm,beatsPerBar:beatsPerBar,now:ProcessInfo.processInfo.systemUptime) else {
            stopEnsembleClock(reason:"Invalid host clock"); return
        }
        let token = UUID()
        ensembleClockToken = token
        ensembleClockRunning = true
        ensembleClockBeat = 0
        ensembleClockStatus = sendMIDI ? "MIDI Clock running" : "Visual tempo running · MIDI off"
        ensembleClockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.patchRunning,self.ensembleClockToken == token else { return }
                switch clock.tick(now:ProcessInfo.processInfo.systemUptime) {
                case .wait(let delay):
                    do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                case .pulse(let beat):
                    if sendMIDI && !self.ensembleClockMIDI.sendRealtime(.clock) {
                        self.stopEnsembleClock(reason:"Clock delivery failed"); return
                    }
                    if let beat { self.ensembleClockBeat = beat }
                case .fault:
                    self.stopEnsembleClock(reason:"Clock deadline missed · restart explicitly"); return
                }
            }
        }
    }

    @discardableResult
    private func clearEnsembleClockDebt() -> Bool {
        guard ensembleClockStopDebt else { return true }
        guard ensembleClockMIDI.sendRealtime(.stop) else {
            ensembleClockStatus = "Clock Stop delivery failed · reset DAW and retry Stop"
            return false
        }
        ensembleClockStopDebt = false
        return true
    }

    func stopEnsembleClock(reason:String = "Clock idle") {
        ensembleClockToken = nil
        ensembleClockTask?.cancel()
        ensembleClockTask = nil
        ensembleClockRunning = false
        ensembleClockBeat = 0
        if clearEnsembleClockDebt() { ensembleClockStatus = reason }
    }
    @Published private(set) var patchMIDIEnabled = false
    @Published private(set) var patchPhysical = false
    @Published private(set) var patchHybridSource: SensorSource?
    @Published private(set) var patchActiveSurfaces: Set<SensorSource> = []
    private var patchPhysicalRuntime = PhysicalPatchRuntime()
    private var patchRemoteTransport: RemoteLoopbackTransport?
    private var patchRemotePage: RemoteLoopbackPageServer?
    @Published private(set) var patchRemotePageReady = false
    @Published private(set) var patchRemoteEndpoint: RemoteEndpoint?
    @Published private(set) var remoteLoopbackVerified = false
    private var patchRemoteBridge: RemoteHostBridge?
    @Published private(set) var patchRemoteReady = false
    @Published private(set) var patchRemotePeers: Set<UUID> = []
    @Published private(set) var patchRemoteProbeStatus = "Not tested"
    @Published private(set) var patchRemoteProbeRunning = false
    private var patchRemoteProbeTask: Task<Void, Never>?
    private var patchRemoteProbeToken: UUID?
    private var patchMailbox: PatchSurfaceMailbox?
    private var patchWatchdog: Task<Void, Never>?
    private var patchHinge: MacBookHingeAngleSource?
    private var patchCamera: BuilderCameraSource?
    private var retiringPatchCamera: BuilderCameraSource?
    private var airTracking = AirTrackingGate()
    private var patchCameraLastFrame: Double = 0
    private var patchCameraReceivedFrame = false
    @Published private(set) var patchCameraChoices: [BuilderCameraSource.Choice] = []
    @Published var patchCameraDeviceID = ""
    @Published var patchCameraOrientation: AirControlOrientation = .upright
    @Published var patchCameraMirrorX = false
    @Published var patchCameraSwapRoles = false
    @Published private(set) var patchAirLiveSelected: Int?
    @Published private(set) var patchAirLiveSounding: Int?
    @Published private(set) var patchAirDebugSelected: Int?
    @Published private(set) var patchAirDebugSounding: Int?
    @Published private(set) var patchAirRecording = false
    @Published private(set) var patchAirTraceCount = 0
    @Published private(set) var patchAirReplaying = false
    private var patchAirTrace = AirFrameTrace()
    private var patchAirReplayTask: Task<Void, Never>?
    private var patchAirReplayToken: UUID?
    var patchAirRecordAvailable: Bool {
        patchRunning && patchPhysical && patchCamera != nil &&
            AirDualHandPerformance.usesDualCamera(instrumentPatch.routes)
    }
    var patchAirDebugAvailable: Bool { patchRunning && (patchPhysical ? patchHybridSource == .camera && AirDualHandPerformance.usesDualCamera(instrumentPatch.routes) : patchSimulation.hasDualCamera) }
    var patchHelperDebugAvailable: Bool { patchRunning && (patchPhysical ? patchHybridSource == .camera && AirHandsHelper.uses(instrumentPatch.routes) && !AirDualHandPerformance.usesDualCamera(instrumentPatch.routes) : patchSimulation.hasHelperHands && !patchSimulation.hasDualCamera) }
    var patchCombinedDebugAvailable: Bool { patchAirDebugAvailable && (patchPhysical ? AirHandsHelper.uses(instrumentPatch.routes) : patchSimulation.hasHelperHands) }
    @Published private(set) var patchCameraStatus = "Camera OFF"
    @Published private(set) var patchCameraHand: AirHandSample?
    var patchCameraCalibrationAvailable: Bool { patchRunning && patchPhysical && !patchMIDIEnabled && patchCameraHand != nil }
    private var patchNativeToken: UUID?
    private var patchGamepadPollSources: [SensorSource] = []
    @Published private(set) var patchNativeBar = false
    @Published private(set) var patchLidStatus = "Builder lid OFF"
    @Published private(set) var patchLidDegrees: Double?
    private var patchPadTasks: [PatchSimulation.Input: Task<Void, Never>] = [:]
    private var patchPadTokens: [PatchSimulation.Input: UUID] = [:]
    private var surfaceMonitorToken: UUID?
    private var surfaceInventoryTask: Task<Void,Never>?
    private var handlingSurfaceInventoryFault = false
    private var surfaceInbox: OrderedTouchInbox<QueuedTouchSnapshot>?
    private var surfaceSnapshotCursor = TouchPublicationCursor()
    private var helperPedalPublicationFence = TouchConsumerPublicationFence()
    private var helperEffectsPublicationFence = TouchConsumerPublicationFence()
    private var touchDispatchMetrics = TouchDispatchMetrics()
    private var touchPreviewCadence = TouchPreviewCadence()
    private var helperPreviewCadence = TouchPreviewCadence()
    // Unthrottled state for musical processing and physical-click attribution.
    private var liveTouchStates: [TouchPerformanceState] = []
    private var liveHelperStates: [HelperSurfaceContact] = []
    private var clickTouchingSurfaces: Set<TouchSurfaceKind> = []
    private var clickSnapshotRevision: UInt64?
    private var clickSnapshotReceivedAt: Double?
    private var physicalClickDown = false
    private var physicalClickReceipt:Double?
    private var helperClickFence = PhysicalClickSessionFence()
    private var touchClickFence = PhysicalClickSessionFence()
    @Published private(set) var sequenceRunning = false
    @Published private(set) var sequenceStatus = "Sequencer MIDI idle"
    private let sequenceMIDI = ChordMIDIOutput(name: "TIHULU Sequencer")
    private let tunedSequenceMIDI = ChordMIDIOutput(name:"TIHULU Tuned Sequencer MPE")
    private var sequenceUsesTuning = false
    private var sequenceSelectors = MIDISelectorCleanup()
    private var activeSequenceMIDI:ChordMIDIOutput { sequenceUsesTuning ? tunedSequenceMIDI : sequenceMIDI }
    private func releaseSequenceOutput() -> Bool {
        let port = activeSequenceMIDI
        let notesReleased = sequenceLedger.releaseAll(send:{ port.send($0) })
        let selectorsReleased = sequenceSelectors.releaseAll(send:{ port.send($0) })
        return notesReleased && selectorsReleased
    }

    func startTunedNoteSequence(output:MusicalOutput,loop:Bool,makeClip:() throws -> MIDIClip) {
        guard !sequenceRunning,output.sendsMIDI,!output.sendsHaptics else {
            sequenceStatus = "Choose MIDI-only output for tuned sequencer playback."
            return
        }
        guard let scale = chordBank.customScale,scale.isMicrotonal else {
            sequenceStatus = "Select a custom scale with nonzero cent offsets first."
            return
        }
        do {
            let tuned = try TunedMIDIClip(makeClip(),scale:scale,root:chordBank.root)
            startLiveSequence(output:output,loop:loop,tuned:tuned,makeClip:{ tuned.clip })
        } catch { sequenceStatus = error.localizedDescription }
    }
    private var sequenceLedger = MIDIClipNoteLedger()
    private var sequenceTask: Task<Void, Never>?
    private var sequenceToken: UUID?
    private var sequenceOwnsHaptics = false
    @Published var midiRunning = false
    @Published private(set) var chordBank = StudioController.readChordBank()
    @Published private(set) var chordArmed = false {
        didSet { touchBarBridge?.refreshChordControls() }
    }
    @Published private(set) var chordActiveSlots: Set<Int> = []
    @Published private(set) var chordStatus = "Output off"
    private let chordOutput = ChordMIDIOutput()
    private let chordMPEOutput = ChordMIDIOutput(name: "TIHULU Chord MPE")
    private var chordMPEState = ChordMPEState()
    // Retain the actual endpoint selection until all attempted notes are released.
    private var chordMPEActive = false
    private var chordMPESelectors = MIDISelectorCleanup()
    private var activeChordMIDIOutput: ChordMIDIOutput { chordMPEActive ? chordMPEOutput : chordOutput }
    private var chordHaptics: LiveNoteHapticOutput?
    @Published private(set) var sharedNoteOutputEnabled = false
    private var sharedNoteOutput: SharedLiveNoteOutput?
    private var chordHapticToken: UUID?
    private var voiceRenderCancellation: VoiceRenderCancellation?
    private var renderGeneration: UInt64 = 0 {
        didSet {
            if oldValue != renderGeneration {
                voiceRenderCancellation?.cancel()
                voiceRenderCancellation = nil
            }
        }
    }
    private var engineGeneration: UInt64 = 0
    private var midiSessionEpoch = LegacyReceiveEpoch()
    var chordOwnsHaptics: Bool { chordArmed && chordBank.effectiveOutput.sendsHaptics }
    @Published private(set) var touchBarOutputArmed = false
    @Published private(set) var touchBarOutputStatus = "Optional Trackpad output off"
    private var touchBarHaptics: LiveNoteHapticOutput?
    private let touchBarDedicatedMIDI = ChordMIDIOutput(name: "TIHULU Touch Bar")
    private var touchBarLocalState = TouchBarNoteState()
    private var touchBarOutputLedger = TouchBarOutputLedger()
    private var touchBarOutputToken: UUID?
    private var nativePianoTokens: [Int: UUID] = [:]
    private(set) var touchBarGestureEpoch = TouchBarGestureEpoch()
    var touchBarOwnsHaptics: Bool { touchBarOutputArmed }
    var liveNoteOwnsHaptics: Bool { chordOwnsHaptics || touchBarOwnsHaptics || gamepadHaptics != nil || groupHaptics != nil }
    @Published private(set) var chordProgression = StudioController.readChordProgression()
    @Published private(set) var progressionRunning = false
    @Published private(set) var progressionStep: Int?
    @Published private(set) var progressionSingleSlot: Int?
    private var progressionTask: Task<Void, Never>?
    private var progressionToken: UUID?
    private var chordState = ChordPadState()
    private var chordTimers: [Int: Task<Void, Never>] = [:]
    private var chordTimerTokens: [Int: UUID] = [:]
    private var chordOutstanding: Set<SensorDestination> = []
    @Published var touchRunning = false
    @Published var touchPreviewRunning = false
    @Published var touchContact = TrackpadContact()
    @Published var magicMouseOrientation = SurfaceOrientation(rawValue: UserDefaults.standard.string(forKey: "TIHULU.magicMouseOrientation") ?? "") ?? .horizontal
    @Published var touchStates: [TouchPerformanceState] = []
    @Published var midiHelperStates: [HelperSurfaceContact] = []
    @Published var midiHelperRunning = false
    @Published var midiHelperSustainActive = false
    @Published var midiHelperTrackpadSustainActive = false
    @Published var midiHelperMagicMouseSustainActive = false
    @Published var touchInstrumentSustainActive = false
    @Published var pointerCaptured = false
    @Published var captureArmed = false
    @Published var captureShortcut = StudioController.readSavedCaptureShortcut()
    @Published var captureStatus = "Cursor free · capture is OFF by default"
    @Published var touchBarProfile = StudioController.readTouchBarProfile()
    @Published var touchBarSustainOn = false
    @Published var simulatedHingeAngle = 90.0
    @Published var liveHingeEnabled = false
    @Published var hingeSensorStatus = "Hardware sensor OFF · manual simulator available"
    @Published private(set) var hingeProbeStatus = "Not probed"
    @Published private(set) var nativeTouchBarItemRequests: UInt64 = 0
    @Published private(set) var nativeTouchBarInputCount: UInt64 = 0
    @Published var activeMIDINotes: [ActiveMIDINote] = []
    @Published var systemAudioRunning = false
    @Published var systemAudioStarting = false
    @Published var systemAudioStopping = false
    @Published var speakerProfile: AudioHapticProfile = .voice
    @Published var speakerOptimized = true
    @Published var speakerAutomaticGain = true
    @Published var speakerNoiseGate = true
    @Published var speakerBufferMS = 150.0

    var speakerBusy: Bool { systemAudioRunning || systemAudioStarting || systemAudioStopping }
    private var speakerTask: Task<Void, Never>?
    private var speakerGeneration: UInt64 = 0
    @Published var lastMIDIMessage = "No MIDI received yet"
    @Published var currentFileName = "No file loaded"
    @Published var activeProfile: AudioHapticProfile = .fullMix

    private var driver: HapticTrackpadDriver?
    private var playback: HapticPlaybackEngine?
    nonisolated static let startupGreeting = "KOMUTAN LOGAR, BİR CİSİM YAKLAŞIYOR EFENDİM."
    private var startupGreetingAttempted = false
    private var startupGreetingPlaying = false
    private var startupGreetingTask: Task<Void, Never>?
    private var touch: TouchInstrumentService?
    private var midi: MIDIHapticService?
    private var systemAudio: SystemAudioHapticCapture?
    private var currentTouchConfiguration = TouchInstrumentConfiguration()
    @Published private(set) var touchCustomScale: CustomScale?
    private var touchMIDIOutEnabled = false
    private var touchMIDIMode: TouchMIDIMode = .standard
    private var touchMultiTouchEnabled = true
    private var touchMIDIChannel = 0
    private var touchSeparateChannels: DAWSurfaceChannels?
    private var touchIndependentDAWSustain = false

    @Published private(set) var keyboardAuditRunning = false
    @Published private(set) var keyboardAuditResult:KeyboardOutputAudit?
    func startKeyboardAudit() {
        guard !keyboardAuditRunning,requireEngine(),let midi else { return }
        midi.beginKeyboardOutputAudit()
        keyboardAuditResult = nil
        keyboardAuditRunning = true
    }
    func finishKeyboardAudit() {
        guard keyboardAuditRunning else { return }
        keyboardAuditResult = midi?.endKeyboardOutputAudit()
        keyboardAuditRunning = false
    }
    private var helperAssignments = MIDIHelperAssignments.sustainOnly
    private var helperSharePedalSurface = false
    private var helperSendToDAW = true
    private var helperTargetChannel = 0
    private var helperPitchBendRange = 12
    private var helperConfigureReceiverBendRange = false
    private var helperVibratoCC = 1
    private var helperExpressionCC = 11
    private var helperLocalSound = false
    private var helperSurfaceSelection: TouchSurfaceSelection = .trackpad
    private var helperSustainSettings = MIDIHelperSustainSettings()
    private var helperSustainState = MIDIHelperSustainState()
    private var helperRearmGate = HelperRearmGate()
    private var helperEffectsRearmGate = HelperRearmGate()
    private var touchSustainSettings = MIDIHelperSustainSettings()
    private var touchSustainState = MIDIHelperSustainState()
    private var touchSustainRearmGate = HelperRearmGate()
    private var captureMonitor: PerformanceCaptureMonitor?
    private var captureHealthTask: Task<Void,Never>?
    private var captureGeneration: UInt64 = 0
    private var lastRetiredCaptureStatus: String?
    private var lastRetiredCaptureSnapshot:PerformanceCaptureDiagnosticSnapshot?
    private var captureHotkeyArmed = false
    private var instrumentPreviewRequested = false
    private var helperPreviewRequested = false
    private var touchBarBridge: StudioTouchBarBridge?
    private var hingeSensor: MacBookHingeAngleSource?
    private var midiTouchBarNotes = TouchBarNoteState()
    private var clickedSurface: TouchSurfaceKind?
    private var clickAttributionNotBefore:Double?
    private var trackpadClickPressure: Double?
    private var activeMIDINoteMap: [String: ActiveMIDINote] = [:]

    private static func readInstrumentPatch() -> InstrumentPatch {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.instrumentPatch.v1"),
              let patch = try? InstrumentPatch.read(data) else { return .starter }
        return patch
    }

    func updateInstrumentPatch(_ proposed: InstrumentPatch) {
        guard !patchRunning, let data = try? proposed.archive() else { return }
        instrumentPatch = proposed
        builderDraftSession.clear()
        UserDefaults.standard.set(data, forKey: "TIHULU.instrumentPatch.v1")
    }

    func resumeBuilderDraft() -> InstrumentPatch {
        guard !patchRunning else { return instrumentPatch }
        return builderDraftSession.resume(saved:instrumentPatch)
    }

    func rememberBuilderDraft(_ draft: InstrumentPatch) {
        guard !patchRunning else { return }
        builderDraftSession.remember(draft,saved:instrumentPatch)
    }

    func discardBuilderDraft() {
        builderDraftSession.clear()
    }

    func refreshBuilderCameras() {
        guard !patchRunning else { return }
        patchCameraChoices = BuilderCameraSource.choices()
    }

    // Internal explicit loopback test entry point. No UI or LAN exposure until
    // certificate provisioning and trusted browser flow are implemented.
    func startInstrumentPatch(sendMIDI: Bool, physical: Bool = false,
                              remoteTransport: RemoteLoopbackTransport? = nil,
                              remotePage: RemoteLoopbackPageServer? = nil,
                              synthetic:SensorSource? = nil,tunedAir:Bool = false, sendHaptics:Bool = false,
                              gamepadOutputSelection:GamepadOutputSelection? = nil) {
        guard !patchRunning, !groupGamepadsRunning else {
            if groupGamepadsRunning { patchStatus = "Stop group MIDI before starting Builder." }
            return
        }
        var requestedPlan: GamepadOutputPlan?
        if let selection = gamepadOutputSelection {
            guard physical,synthetic == nil,remoteTransport == nil,!tunedAir,
                  let plan = GamepadOutputPlan(patch:instrumentPatch,selection:selection) else {
                patchStatus = "Separate controller outputs require 2–4 native gamepad slots and no shared channels with different output choices."
                return
            }
            requestedPlan = plan
        }
        let sendMIDI = requestedPlan?.hasMIDI ?? sendMIDI
        let sendHaptics = requestedPlan?.hasHaptics ?? sendHaptics
        if sendHaptics {
            guard physical, synthetic == nil, remoteTransport == nil, !tunedAir,
                  GamepadHapticVoices.supports(instrumentPatch) else {
                patchStatus = "Trackpad output currently requires a native gamepad-only patch."
                return
            }
            guard permitsLiveNoteSharing, !touchRunning, !midiRunning, !midiHelperRunning,
                  !isPlaying, !liveHingeEnabled, !captureArmed, !pointerCaptured else {
                patchStatus = "Stop competing haptic sessions and the MIDI bridge, or enable shared live notes before arming."
                return
            }
            cancelStartupGreeting()
            guard requireEngine(), driver != nil else {
                patchStatus = "Force Touch output unavailable. Choose MIDI only."
                return
            }
        }
        var requestedTuning:AirTunedOutput?
        if tunedAir {
            guard sendMIDI,remoteTransport == nil,synthetic == nil,let scale = chordBank.customScale else {
                patchStatus = "Tuned Air requires dedicated MIDI, custom scale and no Hybrid/Remote."
                return
            }
            do { requestedTuning = try AirTunedOutput(patch:instrumentPatch,scale:scale,root:chordBank.root) }
            catch { patchStatus = error.localizedDescription; return }
        }
        guard synthetic == nil || physical else {
            patchStatus = "Hybrid requires native input mode."
            return
        }
        let sources = Set(instrumentPatch.routes.map(\.source)).subtracting(synthetic.map { [$0] } ?? [])
        let needsSurface = sources.contains(.trackpad) || sources.contains(.magicMouse)
        let hasRemoteRoutes = sources.contains(.phone) || sources.contains(.tablet)
        guard (remotePage == nil || remoteTransport?.endpoint == remotePage?.endpoint),
              (remoteTransport?.endpoint.isLoopback ?? true) || remoteLoopbackVerified,
              remoteTransport == nil || (physical && hasRemoteRoutes) else {
            patchStatus = "Remote test requires native phone/tablet routes."
            return
        }
        if physical {
            guard synthetic.map({ PhysicalPatchRuntime.supportsHybrid(instrumentPatch,synthetic:$0,allowRemote:remoteTransport != nil) }) ?? PhysicalPatchRuntime.supports(instrumentPatch, allowRemote:remoteTransport != nil) else {
                patchStatus = "Unsupported live source or signal. Use Simulation or edit the routes."
                return
            }
            if sources.contains(.camera) {
                if let retiringPatchCamera, !retiringPatchCamera.isStopped {
                    patchStatus = "Previous camera is stopping. Start again once released."
                    return
                }
                retiringPatchCamera = nil
                switch BuilderCameraSource.authorization {
                case .authorized: break
                case .notDetermined:
                    patchStatus = "Grant camera permission, then start explicitly again."
                    AVCaptureDevice.requestAccess(for: .video) { _ in }
                    return
                default:
                    patchStatus = "Camera permission denied or restricted. Check System Settings."
                    return
                }
            }
            if sources.contains(.lid) && liveHingeEnabled {
                patchStatus = "Stop the independent Tilt sensor before starting Builder lid input."
                return
            }
            if needsSurface {
                guard requireEngine(), touch != nil else {
                    patchStatus = "Native surface monitoring unavailable on this Mac."
                    return
                }
            }
        }
        guard releaseBuilderOutput() else {
            patchStatus = "Unreleased MIDI controls. Reset the DAW and retry Stop."
            return
        }
        do {
            try patchLedger.configure(instrumentPatch)
            if physical && !builderGamepads.bind(required:sources,choices:gamepadBindings) {
                patchStatus = "Select distinct connected gamepads for all mapped slots, then Start again."
                return
            }
            if let requestedTuning {
                airTunedPlan = requestedTuning
                try airTunedMIDI.open()
                guard airTunedSelectors.configure(requestedTuning.setupCommands,send:{ airTunedMIDI.send($0) }) else {
                    stopInstrumentPatch()
                    patchStatus = "Tuned Air MPE setup failed. Check DAW and retry Stop."
                    return
                }
            } else if sendMIDI { try patchMIDI.open() }
            if physical {
                try patchPhysicalRuntime.configure(instrumentPatch, allowRemote: remoteTransport != nil,synthetic:synthetic)
                patchHybridSource = synthetic
                let excluded:TouchSurfaceKind? = synthetic == .trackpad ? .trackpad : synthetic == .magicMouse ? .magicMouse : nil
                let mailbox = PatchSurfaceMailbox(excludedSurface:excluded)
                patchMailbox = mailbox
                patchPhysical = true
                patchNativeToken = UUID()
                patchGamepadPollSources = sources.intersection(GamepadFrame.sources).sorted { $0.rawValue < $1.rawValue }
                if needsSurface {
                    touch?.setPatchMailbox(mailbox)
                    refreshSharedSurfaceMonitoring()
                    guard touchPreviewRunning else {
                        stopInstrumentPatch()
                        patchStatus = "Shared native surface monitoring failed."
                        return
                    }
                    let physicalSources = Set(sources).filter { $0 != synthetic }
                    if let message = missingNativeSurfaceMessage(nativeSurfaces(for:physicalSources)) {
                        stopInstrumentPatch()
                        patchStatus = message
                        return
                    }
                }
                patchInputs = patchPhysicalRuntime.hybridInputs
                patchActiveSurfaces = []
            } else {
                try patchSimulation.start(instrumentPatch, now: ProcessInfo.processInfo.systemUptime)
                patchInputs = patchSimulation.inputs
            }
            if sendHaptics, let driver {
                let token = UUID()
                let output = makeLiveNoteOutput(driver:driver,source:.gamepad)
                gamepadHaptics = output
                gamepadHapticToken = token
                gamepadHapticVoices = GamepadHapticVoices()
                lastGamepadHapticFrame = nil
                try output.start { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.gamepadHapticToken == token else { return }
                        self.stopInstrumentPatch()
                        self.patchStatus = "Gamepad Trackpad output failed: " + message
                    }
                }
            }
            gamepadOutputPlan = requestedPlan
            patchGamepadOutputSelection = gamepadOutputSelection
            patchHapticEnabled = sendHaptics
            patchMIDIEnabled = sendMIDI
            patchTunedAirActive = requestedTuning != nil
            debugCameraRunToken = UUID()
            patchRunning = true
            beginEnsembleTakeIfArmed()
            patchMonitorBuffer = BuilderCommandMonitor.Buffer()
            builderPerformanceMetrics = BuilderPerformanceMetrics()
            patchMessages = []
            patchStatus = physical ? (synthetic == nil ? "Native input requested · waiting for a physical contact" : "Hybrid · explicit synthetic source · waiting for input") :
                (sendMIDI ? "Simulated inputs · live TIHULU Instrument Builder MIDI" : "Simulation only · no MIDI output")
            if physical {
                if sources.contains(.touchBar) {
                    patchNativeBar = true
                    installTouchBar()
                }
                if sources.contains(.lid) {
                    guard let token = patchNativeToken else { stopInstrumentPatch(); return }
                    let sensor = MacBookHingeAngleSource()
                    patchHinge = sensor
                    sensor.onAngle = { [weak self] degrees,receipt in
                        guard let self, self.patchNativeToken == token, self.patchRunning else { return }
                        self.patchLidDegrees = degrees
                        self.receiveBuilderScalar(.lid, value: PhysicalPatchRuntime.normalizedLid(degrees),hostTime:receipt)
                    }
                    sensor.onLoss = { [weak self, weak sensor] reason in
                        guard let self, let sensor, self.patchHinge === sensor, self.patchNativeToken == token else { return }
                        self.patchLidDegrees = nil
                        self.patchLidStatus = reason
                        self.receiveBuilderScalar(.lid, value: nil)
                    }
                    if !sensor.start() {
                        let reason = sensor.status
                        stopInstrumentPatch()
                        patchLidStatus = reason
                        patchStatus = reason
                        return
                    }
                    guard patchRunning, patchNativeToken == token else { sensor.stop(); return }
                    patchLidStatus = sensor.status
                }
                if sources.contains(.camera) {
                    let camera = BuilderCameraSource()
                    patchCamera = camera
                    patchCameraStatus = "Starting camera · local hand tracking"
                    airTracking.reset()
                    patchCameraLastFrame = ProcessInfo.processInfo.systemUptime
                    patchCameraReceivedFrame = false
                    camera.start(deviceID: patchCameraDeviceID,
                                 dualMode: AirDualHandPerformance.usesDualCamera(instrumentPatch.routes),
                                 swapRoles: patchCameraSwapRoles,
                                 helperMode: AirHandsHelper.uses(instrumentPatch.routes))
                }
                if let remoteTransport {
                    patchRemoteBridge = RemoteHostBridge()
                    patchRemoteTransport = remoteTransport
                    patchRemoteReady = false
                    patchRemotePeers = []
                    patchRemoteProbeStatus = "Waiting for loopback listener"
                    patchRemoteEndpoint = remoteTransport.endpoint
                    patchRemotePage = remotePage
                    patchRemotePageReady = false
                    remoteTransport.start()
                    remotePage?.start()
                }
                // Arm from a real initial snapshot, then process native value
                // changes without waiting for the 20 ms watchdog.
                if let token = patchNativeToken {
                    pollBuilderGamepads(token:token)
                    if patchRunning {
                        builderGamepads.beginEventsWithReceipt { [weak self] source,frame,receipt in
                            self?.receiveBuilderGamepad(source:source,frame:frame,token:token,hostTime:receipt)
                        }
                    }
                }
                if patchRunning { startPatchWatchdog() }
            } else if patchSimulation.hasDualCamera || patchSimulation.hasHelperHands {
                startAirDebugWatchdog()
            }
        } catch {
            stopInstrumentPatch()
            patchStatus = error.localizedDescription
        }
    }

    func issueBuilderRemoteInvitation(source: SensorSource, mappingDetails: Bool = false, mappingLabels: Bool = false) throws -> Data {
        guard patchRunning, patchPhysical, patchRemoteTransport != nil, var bridge = patchRemoteBridge
        else { throw RemoteTouchError.unavailable }
        let secret = try RemoteLoopbackTransport.invitation()
        try bridge.issue(secret: secret, source: source, now: ProcessInfo.processInfo.systemUptime,
                         runtime: &patchPhysicalRuntime, mappingDetails: mappingDetails, mappingLabels: mappingLabels)
        patchRemoteBridge = bridge
        return secret
    }

    func cancelBuilderRemoteInvitation() { patchPhysicalRuntime.cancelRemotePairing() }

    func runBuilderRemoteProbe(source: SensorSource) {
        guard patchRemoteReady, patchRemoteEndpoint?.isLoopback == true, !patchRemoteProbeRunning else { return }
        do {
            let expected = try RemoteProbeContract.expected(patch:instrumentPatch,source:source,synthetic:patchHybridSource)
            let invitation = try issueBuilderRemoteInvitation(source: source)
            let token = UUID()
            patchRemoteProbeToken = token
            patchRemoteProbeRunning = true
            patchRemoteProbeStatus = "Testing TLS, pairing and metadata…"
            patchRemoteProbeTask = Task { [weak self] in
                do {
                    try await RemoteLoopbackProbe.run(invitation: invitation, expected:expected)
                    guard let self, self.patchRemoteProbeToken == token else { return }
                    self.remoteLoopbackVerified = true
                    self.patchRemoteProbeStatus = expected.touch ? "TLS, pairing, metadata and touch/release ACKs received. Check command monitor." : "TLS, pairing, metadata and idle heartbeat ACK received. No performance output tested."
                } catch {
                    guard let self, self.patchRemoteProbeToken == token else { return }
                    self.patchRemoteProbeStatus = "Loopback test failed. Check certificate trust and listener; no trust bypass."
                }
                guard let self, self.patchRemoteProbeToken == token else { return }
                self.patchPhysicalRuntime.cancelRemotePairing()
                self.patchRemoteProbeTask = nil
                self.patchRemoteProbeToken = nil
                self.patchRemoteProbeRunning = false
            }
        } catch {
            patchRemoteProbeStatus = "Could not issue test invitation. Check mapped source and listener."
        }
    }

    func revokeBuilderRemote(_ connection: UUID) {
        guard var bridge = patchRemoteBridge, let transport = patchRemoteTransport else { return }
        let result = bridge.revoke(connection,now:ProcessInfo.processInfo.systemUptime,runtime:&patchPhysicalRuntime)
        patchRemoteBridge = bridge
        patchRemotePeers = bridge.connectionIDs
        recordPatchCommands(result.commands)
        guard patchRunning,patchRemoteTransport === transport else { return }
        if result.fault {
            stopInstrumentPatch()
            patchStatus = "Remote clock fault. Outputs released; restart explicitly."
            return
        }
        for action in result.actions {
            if case .revoke(let id) = action { transport.revoke(id) }
        }
    }

    private func drainBuilderRemote(now: Double) {
        guard let transport = patchRemoteTransport, var bridge = patchRemoteBridge else { return }
        if let page = patchRemotePage {
            switch page.status {
            case .failed, .stopped:
                stopInstrumentPatch()
                patchStatus = "HTTPS page server failed. Outputs released."
                return
            case .ready: if !patchRemotePageReady { patchRemotePageReady = true }
            case .starting: break
            }
        }
        let events = transport.drain()
        let result = bridge.process(events, now: ProcessInfo.processInfo.systemUptime, runtime: &patchPhysicalRuntime)
        patchRemoteBridge = bridge
        if patchRemoteReady != bridge.ready { patchRemoteReady = bridge.ready }
        if patchRemotePeers != bridge.connectionIDs { patchRemotePeers = bridge.connectionIDs }
        recordPatchCommands(result.commands,receipt:result.deliveryReceipt,maximumAge:0.1)
        // MIDI failure or receipt expiry can retire the entire Builder while delivering commands.
        guard patchRunning, patchRemoteTransport === transport else { return }
        if result.fault {
            stopInstrumentPatch()
            patchStatus = "Remote transport fault. Outputs released; restart explicitly."
            return
        }
        for action in result.actions {
            switch action {
            case .acknowledge(let id, let accepted): transport.acknowledge(id, accepted: accepted)
            case .capabilities(let id, let capabilities): transport.acknowledge(id, accepted: true, capabilities: capabilities)
            case .mapping(let id, let page): transport.acknowledge(id, accepted: true, mapping: page)
            case .mappingLabels(let id, let page): transport.acknowledge(id, accepted: true, labels: page)
            case .revoke(let id): transport.revoke(id)
            case .stop: transport.stop()
            }
        }
    }

    private func receiveBuilderScalar(_ source: SensorSource, value: Double?,hostTime:Double? = nil) {
        guard patchRunning, patchPhysical else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let receipt=hostTime ?? now
        guard PhysicalPatchRuntime.admitsPhysicalReceipt(receipt,now:now) else {
            stopInstrumentPatch()
            patchStatus = "Scalar input expired before delivery. Restart Builder explicitly."
            return
        }
        let commands = patchPhysicalRuntime.receiveScalar(source: source, value: value, hostTime:receipt, now:now)
        recordPatchCommands(commands,receipt:receipt)
    }

    var builderBarToken: UUID? { groupNativeBar ? groupRunToken : (patchNativeBar ? patchNativeToken : nil) }

    func builderBarValue(_ value: Double?, token: UUID) {
        if groupNativeBar, groupRunToken == token {
            receiveGroupScalar(.touchBar,value:value,run:token)
            return
        }
        guard patchNativeBar, token == patchNativeToken else { return }
        receiveBuilderScalar(.touchBar, value: value)
    }

    private func startAirDebugWatchdog() {
        patchWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, self.patchAirDebugAvailable || self.patchHelperDebugAvailable else { return }
                let commands = self.patchSimulation.expireDualHand(now: ProcessInfo.processInfo.systemUptime)
                self.refreshAirDebugState()
                self.recordPatchCommands(commands)
            }
        }
    }

    private func refreshAirDebugState() {
        let selected = patchPhysical ? patchPhysicalRuntime.airSelectedSlot : patchSimulation.airSelectedSlot
        let sounding = patchPhysical ? patchPhysicalRuntime.airSoundingSlot : patchSimulation.airSoundingSlot
        if patchAirDebugSelected != selected { patchAirDebugSelected = selected }
        if patchAirDebugSounding != sounding { patchAirDebugSounding = sounding }
    }

    func sendHelperDebugFrame(left:AirHandSample?,right:AirHandSample?,runID:UUID) {
        guard patchHelperDebugAvailable,patchDebugCameraRunID == runID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recordPatchCommands(patchPhysical ? patchPhysicalRuntime.receiveHelperHands(left:left,right:right,hostTime:now,now:now,synthetic:true) : patchSimulation.receiveHelperHands(left:left,right:right,time:now,now:now))
    }

    func releaseHelperDebugFrame(runID:UUID) {
        guard patchHelperDebugAvailable,patchDebugCameraRunID == runID else { return }
        recordPatchCommands(patchPhysical ? patchPhysicalRuntime.releaseHybridSource() : patchSimulation.releaseDualHand())
    }

    func sendAirDebugFrame(count: Int, aperture: Double, x: Double, y: Double,
                           chordHand:AirHandSample? = nil, chordVisible:Bool = true, helperVisible:Bool = true,runID:UUID) {
        guard patchAirDebugAvailable, !patchAirReplaying,patchDebugCameraRunID == runID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let hand = AirHandSample.debugSample(x: x, y: y, aperture: aperture)
        let commands: [SensorCommand]
        if patchCombinedDebugAvailable {
            let chord = chordVisible ? chordHand : nil
            let helper = helperVisible ? hand : nil
            let left = patchCameraSwapRoles ? helper : chord
            let right = patchCameraSwapRoles ? chord : helper
            commands = patchPhysical ? patchPhysicalRuntime.receiveCombinedHands(count:count,confidence:1,left:left,right:right,swapRoles:patchCameraSwapRoles,hostTime:now,now:now,synthetic:true) : patchSimulation.receiveCombinedHands(count:count,confidence:1,left:left,right:right,swapRoles:patchCameraSwapRoles,time:now,now:now)
        } else {
            commands = patchPhysical ? patchPhysicalRuntime.receiveDualHand(count:count,confidence:1,helper:hand,hostTime:now,now:now,synthetic:true) : patchSimulation.receiveDualHand(count: count, confidence: 1, helper: hand, time: now, now: now)
        }
        refreshAirDebugState()
        recordPatchCommands(commands)
    }

    func startAirTrace() {
        guard patchAirRecordAvailable, !patchAirRecording else { return }
        patchAirTrace = AirFrameTrace()
        patchAirTraceCount = 0
        patchAirRecording = true
    }

    func stopAirTrace() { patchAirRecording = false }

    func clearAirTrace() {
        guard !patchAirRecording, !patchAirReplaying else { return }
        patchAirTrace = AirFrameTrace()
        patchAirTraceCount = 0
    }

    var patchAirTraceCompatible: Bool {
        guard !patchPhysical, let mode = patchAirTrace.mode else { return false }
        return patchCombinedDebugAvailable ? mode == .combined(swapRoles:patchCameraSwapRoles) : mode == .dual
    }

    func startAirReplay() {
        guard patchAirDebugAvailable, patchAirTraceCompatible, !patchAirReplaying, !patchAirTrace.frames.isEmpty else { return }
        releaseAirDebugFrame()
        guard patchAirDebugAvailable else { return }
        let frames = patchAirTrace.frames
        let mode = patchAirTrace.mode
        let token = UUID()
        patchAirReplayToken = token
        patchAirReplaying = true
        patchAirReplayTask = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            for frame in frames {
                let deadline = start + frame.offset
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard let self, !Task.isCancelled, self.patchAirReplayToken == token,
                      self.patchAirDebugAvailable else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // Do not burst overdue note edges after a stalled UI.
                guard now - deadline < 0.10 else { self.stopAirReplay(); return }
                let commands:[SensorCommand]
                if case .combined(let swap)? = mode {
                    commands = self.patchSimulation.receiveCombinedHands(count:frame.count,confidence:frame.confidence,
                        left:frame.left,right:frame.right,swapRoles:swap,time:now,now:now)
                } else {
                    commands = self.patchSimulation.receiveDualHand(count:frame.count,confidence:frame.confidence,
                        helper:frame.helper,time:now,now:now)
                }
                self.refreshAirDebugState()
                self.recordPatchCommands(commands)
            }
            guard let self, self.patchAirReplayToken == token else { return }
            self.stopAirReplay()
        }
    }

    func stopAirReplay() {
        patchAirReplayToken = nil
        patchAirReplayTask?.cancel()
        patchAirReplayTask = nil
        patchAirReplaying = false
        releaseAirDebugFrame()
    }

    func releaseAirDebugFrame() {
        guard patchAirDebugAvailable else { return }
        let commands = patchPhysical ? patchPhysicalRuntime.releaseHybridSource() : patchSimulation.releaseDualHand()
        refreshAirDebugState()
        recordPatchCommands(commands)
    }

    private func receiveBuilderGamepad(source:SensorSource,frame:GamepadFrame?,token:UUID,hostTime:Double? = nil) {
        guard patchRunning, patchPhysical, patchNativeToken == token else { return }
        let now=ProcessInfo.processInfo.systemUptime
        let receipt=hostTime ?? now
        guard PhysicalPatchRuntime.admitsPhysicalReceipt(receipt,now:now) else {
            stopInstrumentPatch()
            patchStatus = "Controller snapshot expired before delivery. Restart Builder explicitly."
            return
        }
        let commands = patchPhysicalRuntime.receiveGamepad(source:source,frame:frame,now:now,hostTime:receipt)
        recordPatchCommands(commands,receipt:receipt)
    }

    /// Capture all known losses before reconciling shared MIDI targets.
    /// Every surviving sample retains its original read-start receipt.
    private func pollBuilderGamepads(token:UUID) {
        guard patchRunning,patchPhysical,patchNativeToken==token else { return }
        var snapshots:[(SensorSource,GamepadFrame,Double)] = []
        var departing:Set<SensorSource> = []
        for source in patchGamepadPollSources {
            let receipt=ProcessInfo.processInfo.systemUptime
            if let frame=builderGamepads.read(source) { snapshots.append((source,frame,receipt)) }
            else { departing.insert(source) }
        }
        if !departing.isEmpty {
            recordPatchCommands(patchPhysicalRuntime.releaseGamepads(departing,now:ProcessInfo.processInfo.systemUptime))
        }
        for (source,frame,receipt) in snapshots {
            guard patchRunning,patchNativeToken==token else { return }
            receiveBuilderGamepad(source:source,frame:frame,token:token,hostTime:receipt)
        }
    }

    private func startPatchWatchdog() {
        guard let mailbox = patchMailbox else { return }
        patchWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, self.patchRunning, self.patchPhysical,
                      self.patchMailbox === mailbox else { return }
                self.drainPhysicalPatch(mailbox)
            }
        }
    }

    private func drainPhysicalPatch(_ mailbox: PatchSurfaceMailbox) {
        let tickStart = ProcessInfo.processInfo.systemUptime
        let batch = mailbox.drain()
        let oldest = batch.samples.min(by:{ $0.time < $1.time })?.time
        defer {
            flushPatchMonitor()
            builderPerformanceMetrics.recordTick(start:tickStart,end:ProcessInfo.processInfo.systemUptime,
                                                 oldestSample:oldest)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if batch.overflow || batch.samples.contains(where: { !PhysicalPatchRuntime.admitsPhysicalReceipt($0.time,now:now) }) {
            stopInstrumentPatch()
            patchStatus = "Native input backlog or stale frames. Output released; restart explicitly."
            return
        }
        for sample in batch.samples {
            guard patchRunning else { return }
            // Earlier synchronous MIDI sends may consume most of the
            // receipt budget. Revalidate before every physical frame.
            let admissionNow=ProcessInfo.processInfo.systemUptime
            guard PhysicalPatchRuntime.admitsPhysicalReceipt(sample.time,now:admissionNow) else {
                stopInstrumentPatch()
                patchStatus = "Native input expired during processing. Output released; restart explicitly."
                return
            }
            let surface = sample.frame.surface
            let source: SensorSource = surface == .trackpad ? .trackpad : .magicMouse
            let contact = sample.frame.contacts.lazy.filter { $0.isDown }.min { $0.id < $1.id }
            var x: Double?
            var y: Double?
            var size: Double?
            if let contact, contact.x.isFinite, contact.y.isFinite, contact.size.isFinite {
                let rawX = min(1, max(0, Double(contact.x)))
                let rawY = min(1, max(0, Double(contact.y)))
                let point = surface == .magicMouse ? magicMouseOrientation.transformed(x: rawX, y: rawY) : (rawX,rawY)
                x = point.0
                y = point.1
                size = min(1,max(0,Double(contact.size)))
            }
            let commands = patchPhysicalRuntime.receive(source: source, x: x, y: y, size: size,
                                                        hostTime: sample.time, now: admissionNow)
            recordPatchCommands(commands,receipt:sample.time)
        }
        guard patchRunning else { return }
        drainBuilderCamera(now: ProcessInfo.processInfo.systemUptime)
        guard patchRunning else { return }
        drainBuilderRemote(now: ProcessInfo.processInfo.systemUptime)
        guard patchRunning else { return }
        if let token=patchNativeToken { pollBuilderGamepads(token:token) }
        guard patchRunning else { return }
        let expired = patchPhysicalRuntime.expire(now: ProcessInfo.processInfo.systemUptime)
        recordPatchCommands(expired)
        guard patchRunning else { return }
        if patchHybridSource == .camera { refreshAirDebugState() }
        let selected = patchPhysicalRuntime.airSelectedSlot
        let sounding = patchPhysicalRuntime.airSoundingSlot
        if patchAirLiveSelected != selected { patchAirLiveSelected = selected }
        if patchAirLiveSounding != sounding { patchAirLiveSounding = sounding }
        if patchCamera != nil && !patchPhysicalRuntime.activeSources.contains(.camera) {
            if now - patchCameraLastFrame >= 0.25 || !AirDualHandPerformance.usesDualCamera(instrumentPatch.routes) {
                patchCameraHand = nil
            }
            if now - patchCameraLastFrame >= PhysicalPatchRuntime.timeout {
                airTracking.reset()
            }
            if patchCameraStatus == "One hand tracked" { patchCameraStatus = "Tracking lost · controls released" }
        }
        guard patchRunning else { return }
        let active = patchPhysicalRuntime.activeSources.subtracting(patchHybridSource.map { [$0] } ?? [])
        if active != patchActiveSurfaces {
            patchActiveSurfaces = active
            let native = active.isEmpty ? "No active native input" : "Native input · " + active.map(\.rawValue).sorted().joined(separator: ", ")
            patchStatus = patchHybridSource.map { native + " · Hybrid: " + $0.rawValue + " (synthetic)" } ?? native
        }
    }

    private func stopBuilderCamera(reason: String) {
        stopAirTrace()
        patchAirLiveSelected = nil
        patchAirLiveSounding = nil
        if let camera = patchCamera {
            retiringPatchCamera = camera
            camera.stop()
        }
        patchCamera = nil
        airTracking.reset()
        patchCameraHand = nil
        recordPatchCommands(patchPhysicalRuntime.releaseCamera(now:ProcessInfo.processInfo.systemUptime))
        patchCameraStatus = reason
    }

    private func drainBuilderCamera(now: Double) {
        if let camera = patchCamera {
            if BuilderCameraSource.authorization != .authorized {
                stopBuilderCamera(reason: "Camera permission lost. Restart Builder explicitly.")
                return
            }
            let events = camera.drain()
            for event in events {
                guard patchRunning else { return }
                let now = ProcessInfo.processInfo.systemUptime
                switch event {
                case .ready: patchCameraStatus = "Camera running · show configured hands"
                case .fault(let message):
                    stopBuilderCamera(reason: message)
                    return
                case .combinedFrame(let count,let confidence,let left,let right,let time):
                    let l = left?.oriented(patchCameraOrientation,mirrorX:patchCameraMirrorX)
                    let r = right?.oriented(patchCameraOrientation,mirrorX:patchCameraMirrorX)
                    let fresh=MonotonicReceiptAdmission.permits(receipt:time,now:now,maximumAge:0.25)
                    if fresh {
                        patchCameraReceivedFrame = true
                        patchCameraLastFrame = time
                        if patchAirRecording {
                            if patchAirTrace.appendCombined(count:count,confidence:confidence,left:l,right:r,swapRoles:patchCameraSwapRoles,time:time) {
                                patchAirTraceCount = patchAirTrace.frames.count
                            } else { stopAirTrace() }
                        }
                        patchCameraHand = patchCameraSwapRoles ? l : r
                        patchCameraStatus = "Combined · " + (l == nil ? "Left absent" : "Left tracked") +
                            " · " + (r == nil ? "Right absent" : "Right tracked")
                    } else {
                        patchCameraHand = nil
                        stopAirTrace()
                        patchCameraStatus = "Stale combined frame · released"
                    }
                    recordPatchCommands(patchPhysicalRuntime.receiveCombinedHands(count:count,confidence:confidence,
                        left:l,right:r,swapRoles:patchCameraSwapRoles,hostTime:time,now:now),receipt:fresh ? time : nil,maximumAge:0.25)
                case .helperFrame(let left, let right, let time):
                    let l = left?.oriented(patchCameraOrientation,mirrorX:patchCameraMirrorX)
                    let r = right?.oriented(patchCameraOrientation,mirrorX:patchCameraMirrorX)
                    let fresh=MonotonicReceiptAdmission.permits(receipt:time,now:now,maximumAge:0.25)
                    if fresh {
                        patchCameraReceivedFrame = true
                        patchCameraLastFrame = time
                        patchCameraHand = l ?? r
                        patchCameraStatus = "MIDI Helper · " + (l == nil ? "Left absent" : "Left tracked") +
                            " · " + (r == nil ? "Right absent" : "Right tracked")
                    } else {
                        patchCameraHand = nil
                        patchCameraStatus = "Stale helper frame · released"
                    }
                    recordPatchCommands(patchPhysicalRuntime.receiveHelperHands(left:l,right:r,hostTime:time,now:now),receipt:fresh ? time : nil,maximumAge:0.25)
                case .dualFrame(let count, let confidence, let helper, let time):
                    guard MonotonicReceiptAdmission.permits(receipt:time,now:now,maximumAge:0.25) else {
                        recordPatchCommands(patchPhysicalRuntime.receiveDualHand(count: nil, confidence: 0, helper: nil, hostTime: time, now: now))
                        stopAirTrace()
                        patchCameraHand = nil
                        patchCameraStatus = "Stale dual-hand frame · controls released"
                        continue
                    }
                    patchCameraReceivedFrame = true
                    patchCameraLastFrame = time
                    let oriented = helper?.oriented(patchCameraOrientation, mirrorX: patchCameraMirrorX)
                    if patchAirRecording {
                        if patchAirTrace.append(count: count, confidence: confidence, helper: oriented, time: time) {
                            patchAirTraceCount = patchAirTrace.frames.count
                        } else { stopAirTrace() }
                    }
                    patchCameraHand = oriented
                    patchCameraStatus = count.map { "Chord fingers: \($0) · pinch helper to play" } ?? "Two reliable hands required"
                    recordPatchCommands(patchPhysicalRuntime.receiveDualHand(count: count, confidence: confidence,
                                                                            helper: oriented, hostTime: time, now: now),receipt:time,maximumAge:0.25)
                case .frame(let hand, let time):
                    guard PhysicalPatchRuntime.admitsPhysicalReceipt(time,now:now) else {
                        stopBuilderCamera(reason: "Stale camera frames. Restart Builder explicitly.")
                        return
                    }
                    patchCameraReceivedFrame = true
                    patchCameraLastFrame = time
                    let oriented = hand?.oriented(patchCameraOrientation, mirrorX: patchCameraMirrorX)
                    let accepted = airTracking.accept(oriented, at: time, now: now)
                    patchCameraHand = accepted
                    patchCameraStatus = accepted != nil ? "One hand tracked" :
                        (hand == nil ? "No reliable single hand" : "Acquiring hand")
                    recordPatchCommands(patchPhysicalRuntime.receiveHand(accepted, hostTime: time, now: now),receipt:time)
                }
            }
            guard patchRunning else { return }
            let limit = patchCameraReceivedFrame ? 2.0 : 8.0
            if now - patchCameraLastFrame >= limit {
                stopBuilderCamera(reason: "Camera stopped delivering fresh frames. Restart Builder explicitly.")
                return
            }
        }
    }

    func sendPatchInput(_ input: PatchSimulation.Input, value: Double) {
        guard patchRunning, (!patchPhysical || patchHybridSource != nil), patchInputs.contains(input),
              value.isFinite, (0...1).contains(value) else { return }
        // A later manual input supersedes the pulse's release timer.
        // Do not release its contribution here: the new value owns it.
        cancelPatchPulse(input)
        deliverPatchInput(input, value: value)
    }

    private func cancelPatchPulse(_ input: PatchSimulation.Input) {
        patchPadTasks.removeValue(forKey: input)?.cancel()
        patchPadTokens.removeValue(forKey: input)
    }

    private func deliverPatchInput(_ input: PatchSimulation.Input, value: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let commands = patchPhysical ? patchPhysicalRuntime.sendHybrid(input,value:value,now:now) : patchSimulation.send(input,value:value,now:now)
        recordPatchCommands(commands,receipt:patchPhysical ? now : nil)
    }

    func releasePatchInput(_ input: PatchSimulation.Input) {
        guard patchRunning, (!patchPhysical || patchHybridSource != nil),patchInputs.contains(input) else { return }
        cancelPatchPulse(input)
        let commands: [SensorCommand]
        if patchPhysical { commands = patchPhysicalRuntime.releaseHybrid(input) }
        else if GamepadFrame.sources.contains(input.source) {
            commands = patchSimulation.liftGamepadControl(input,now:ProcessInfo.processInfo.systemUptime)
        } else { commands = patchSimulation.release(input) }
        recordPatchCommands(commands)
    }

    func pulsePatchInput(_ input: PatchSimulation.Input, value: Double = 1) {
        guard patchRunning, (!patchPhysical || patchHybridSource != nil), patchInputs.contains(input),
              value.isFinite, (0...1).contains(value) else { return }
        // Release first for an actual retrigger. No raw-zero synthesis.
        releasePatchInput(input)
        guard patchRunning else { return }
        let token = UUID()
        patchPadTokens[input] = token
        deliverPatchInput(input, value: value)
        guard patchRunning, patchPadTokens[input] == token else { return }
        patchPadTasks[input] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.patchPadTokens[input] == token else { return }
            self.releasePatchInput(input)
        }
    }

    var patchHybridRunID:UUID? { patchHybridSource == nil ? nil : patchNativeToken }

    func refreshHybridControls(runID:UUID) {
        guard patchRunning,patchHybridRunID == runID else { return }
        recordPatchCommands(patchPhysicalRuntime.refreshHybrid(now:ProcessInfo.processInfo.systemUptime))
    }

    func releaseHybridControls() {
        guard patchRunning,let source = patchHybridSource else { return }
        for input in Array(patchPadTasks.keys) where input.source == source { cancelPatchPulse(input) }
        recordPatchCommands(patchPhysicalRuntime.releaseHybridSource())
    }

    func disconnectPatchInput(_ source: SensorSource) {
        guard patchRunning, (!patchPhysical || source == patchHybridSource) else { return }
        if patchPhysical {
            releaseHybridControls()
            patchInputs = []
            return
        }
        for input in Array(patchPadTasks.keys) where input.source == source {
            cancelPatchPulse(input)
        }
        let commands = patchSimulation.disconnect(source)
        patchInputs = patchSimulation.inputs
        recordPatchCommands(commands)
        if !patchSimulation.running { stopInstrumentPatch() }
    }

    private func recordPatchCommands(_ commands: [SensorCommand],receipt:Double? = nil,
                                     maximumAge:Double = PhysicalPatchRuntime.timeout) {
        guard !commands.isEmpty else { return }
        var attempted: [SensorCommand] = []
        var hapticAttack = false
        let batchStart = ProcessInfo.processInfo.systemUptime
        var midiAttempts = 0
        var midiFailures = 0
        defer {
            builderPerformanceMetrics.recordBatch(start:batchStart,end:ProcessInfo.processInfo.systemUptime,
                commands:attempted.count,attempts:midiAttempts,failures:midiFailures)
        }
        var fence=receipt.map { PhysicalReceiptSendFence(receipt:$0,maximumAge:maximumAge) }
        let outcome=PhysicalReceiptCommandBatch.dispatch(commands,fence:&fence,
            now:{ ProcessInfo.processInfo.systemUptime }) { command in
            attempted.append(command)
            let plan = airTunedPlan
            if patchMIDIEnabled && (gamepadOutputPlan?.sendsMIDI(command.destination) ?? true) &&
                !patchLedger.deliver(command, send: { command in
                midiAttempts += 1
                if let plan {
                    guard let wire = plan.translate(command) else { return false }
                    return airTunedMIDI.send(wire)
                }
                return patchMIDI.send(command)
            }) {
                midiFailures += 1
                return false
            }
            if patchHapticEnabled && (gamepadOutputPlan?.sendsHaptics(command.destination) ?? true) {
                gamepadHapticVoices.apply(command)
                if command.destination.kind == .note && command.value > 0 { hapticAttack = true }
            }
            if ensembleRecording {
                if ensembleTake?.append(command,now:ProcessInfo.processInfo.systemUptime) != true { updateEnsembleTakeState() }
            }
            return true
        }
        if outcome != .completed {
            // The router may have computed commands that never reached
            // the sink. Retire Builder only, through its actual output
            // ledger; do not invent debt for unattempted commands.
            if ensembleRecording {
                ensembleTake?.interrupt(now:ProcessInfo.processInfo.systemUptime)
                updateEnsembleTakeState()
            }
            stopInstrumentPatch()
            let reason=outcome == .expired ? "Physical receipt expired during delivery. Restart Builder explicitly." : "MIDI delivery failed. Check DAW."
            patchStatus = reason + " " + patchStatus
        }
        // Deliver synchronously in the original order, publish the bounded
        // monitor only once. A failure still includes the attempted command.
        if patchHapticEnabled { updateGamepadHaptics(attack:hapticAttack) }
        patchMonitorBuffer.append(attempted)
        // Physical playback publishes at watchdog cadence, not per event.
        // Simulation and failure/stop paths still show the last attempted data.
        if !patchPhysical || !patchRunning { flushPatchMonitor() }
    }

    func resetBuilderPerformanceMetrics() {
        builderPerformanceMetrics = BuilderPerformanceMetrics()
        patchPhysicalRuntime.resetGamepadSnapshotMetrics()
    }

    func builderPerformanceReport() -> String {
        let m = builderPerformanceMetrics
        let g = patchPhysicalRuntime.gamepadSnapshotMetrics
        func ms(_ seconds:Double) -> String { String(format:"%.2f ms",seconds*1000) }
        return """
        Native watchdog ticks: \(m.ticks)
        Max tick gap: \(ms(m.maxTickGap)); gaps ≥40 ms: \(m.gapsOver40MS)
        Max watchdog work: \(ms(m.maxTickDuration))
        Max queued surface age: \(ms(m.maxSurfaceQueueAge))
        Logical command batches / commands: \(m.commandBatches) / \(m.logicalCommands)
        MIDI attempts / failures: \(m.midiAttempts) / \(m.midiFailures)
        Max command batch work: \(ms(m.maxBatchDuration))
        Gamepad snapshots / skipped identical: \(g.accepted) / \(g.skippedDuplicates)
        Gamepad mapped events: \(g.mappedEvents)
        Host timing only; not measured audio or physical latency. Cleanup retries excluded.
        """
    }

    private func flushPatchMonitor() {
        if let next = patchMonitorBuffer.flush(previous:patchMessages), next != patchMessages {
            patchMessages = next
        }
    }

    func stopInstrumentPatch() {
        if groupGamepadsRunning { stopGroupGamepads() }
        flushPatchMonitor()
        gamepadHapticToken = nil
        gamepadHaptics?.stop()
        gamepadHaptics = nil
        releaseSharedOutputIfIdle()
        gamepadHapticVoices = GamepadHapticVoices()
        lastGamepadHapticFrame = nil
        patchHapticEnabled = false
        patchGamepadOutputSelection = nil
        gamepadOutputPlan = nil
        builderGamepads.stop()
        stopEnsembleTake()
        stopEnsembleClock()
        stopAirTrace()
        patchAirReplayToken = nil
        patchAirReplayTask?.cancel()
        patchAirReplayTask = nil
        patchAirReplaying = false
        for task in patchPadTasks.values { task.cancel() }
        patchPadTasks.removeAll()
        patchPadTokens.removeAll()
        patchWatchdog?.cancel()
        patchWatchdog = nil
        patchAirDebugSelected = nil
        patchAirDebugSounding = nil
        patchAirLiveSelected = nil
        patchAirLiveSounding = nil
        let hadPhysicalInput = patchPhysical
        let hadNativeBar = patchNativeBar
        patchNativeToken = nil
        patchGamepadPollSources = []
        patchNativeBar = false
        patchRemoteProbeToken = nil
        patchRemoteProbeTask?.cancel()
        patchRemoteProbeTask = nil
        patchRemoteProbeRunning = false
        patchRemoteProbeStatus = "Not tested"
        patchRemotePage?.stop()
        patchRemotePage = nil
        patchRemotePageReady = false
        patchRemoteEndpoint = nil
        patchRemoteTransport?.stop()
        patchRemoteTransport = nil
        patchRemoteBridge = nil
        patchRemoteReady = false
        patchRemotePeers = []
        if let camera = patchCamera {
            retiringPatchCamera = camera
            camera.stop()
        }
        patchCamera = nil
        airTracking.reset()
        patchCameraHand = nil
        patchCameraStatus = "Camera OFF"
        patchHinge?.stop()
        patchHinge = nil
        patchLidDegrees = nil
        patchLidStatus = "Builder lid OFF"
        touch?.setPatchMailbox(nil)
        patchMailbox?.close()
        patchMailbox = nil
        patchPhysical = false
        patchHybridSource = nil
        if hadPhysicalInput { refreshSharedSurfaceMonitoring() }
        if hadNativeBar { installTouchBar() }
        patchActiveSurfaces = []
        _ = patchPhysicalRuntime.stop()
        _ = patchSimulation.stop()
        patchInputs = []
        debugCameraRunToken = nil
        patchRunning = false
        patchMIDIEnabled = false
        patchTunedAirActive = false
        let released = releaseBuilderOutput()
        patchStatus = released ? "Builder idle" : "MIDI release failed. Reset DAW and retry Stop."
    }

    private static func readChordBank() -> ChordBank {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.chordBank.v1"),
              let document = try? WorkspaceArchive.decode(ChordBank.self, from: data),
              document.payload.isValid else { return ChordBank() }
        return document.payload
    }

    func updateChordBank(_ proposed: ChordBank) {
        guard proposed.isValid, !chordArmed, chordOutstanding.isEmpty, chordMPESelectors.isEmpty,
              !(touchRunning && currentTouchConfiguration.hasPhysicalChords) else { return }
        chordBank = proposed
        touchBarBridge?.refreshChordControls()
        if let data = try? WorkspaceArchive.encode(name: "Chord bank", payload: proposed) {
            UserDefaults.standard.set(data, forKey: "TIHULU.chordBank.v1")
        }
    }

    func setSharedNoteOutputEnabled(_ enabled: Bool) {
        guard !liveNoteOwnsHaptics else { return }
        sharedNoteOutputEnabled = enabled
    }

    private var permitsLiveNoteSharing: Bool {
        !sequenceOwnsHaptics && !speakerBusy && (!liveNoteOwnsHaptics || sharedNoteOutputEnabled)
    }

    private func makeLiveNoteOutput(driver: HapticTrackpadDriver, source: HapticMixSource) -> LiveNoteHapticOutput {
        if sharedNoteOutputEnabled {
            if sharedNoteOutput == nil { sharedNoteOutput = SharedLiveNoteOutput(driver: driver) }
            return LiveNoteHapticOutput(driver: driver, shared: sharedNoteOutput, sourceKind: source)
        }
        return LiveNoteHapticOutput(driver: driver, sourceKind: source)
    }

    private func releaseSharedOutputIfIdle() {
        guard chordHaptics == nil, touchBarHaptics == nil, gamepadHaptics == nil else { return }
        sharedNoteOutput?.retire()
        sharedNoteOutput = nil
    }

    func armChordPads() {
        guard !groupGamepadsRunning else { chordStatus = "Stop group MIDI first."; return }
        guard !chordArmed else { return }
        releaseChordPads()
        guard chordOutstanding.isEmpty, chordMPESelectors.isEmpty else {
            chordStatus = "Unreleased MIDI notes or selectors. Reset the receiving DAW before retrying."
            return
        }
        let selected = chordBank.effectiveOutput
        guard chordBank.permitsSelectedOutput else {
            chordStatus = "Choose Trackpad, enable dedicated MPE, or explicitly allow equal-tempered MIDI in Scale Editor."
            return
        }
        if selected.sendsHaptics {
            guard (gamepadHaptics == nil && !touchBarOwnsHaptics) || sharedNoteOutputEnabled,
                  !speakerBusy, !touchRunning, !midiHelperRunning, !midiRunning,
                  !isPlaying, !sequenceOwnsHaptics, !liveHingeEnabled, !captureArmed, !pointerCaptured else {
                chordStatus = "Stop other haptic performances and the MIDI bridge first, or choose MIDI only."
                return
            }
            cancelStartupGreeting()
            renderGeneration &+= 1
            playback?.stop(closeDriver: false)
            guard requireEngine(), let driver else {
                chordStatus = "Force Touch output unavailable. MIDI-only mode remains available."
                return
            }
            chordHaptics = makeLiveNoteOutput(driver: driver, source: .chords)
        }
        do {
            chordMPEActive = chordBank.usesMPE
            if selected.sendsMIDI {
                try activeChordMIDIOutput.open()
                if chordMPEActive {
                    guard chordMPESelectors.configure(ChordMPEState.configuration(), send:{ chordMPEOutput.send($0) }) else {
                        _ = chordMPESelectors.releaseAll(send:{ chordMPEOutput.send($0) })
                        throw ChordMPEConfigurationError.delivery
                    }
                }
            }
            if selected.sendsHaptics {
                let token = UUID()
                chordHapticToken = token
                try chordHaptics?.start { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.chordHapticToken == token else { return }
                        self.disarmChordPads()
                        self.chordStatus = "Trackpad output failed: " + message
                    }
                }
            }
            chordArmed = true
            chordStatus = selected.rawValue + (selected.sendsHaptics && sharedNoteOutputEnabled ? " ready (shared experimental)" : " ready")
            if chordMPEActive {
                chordStatus += " · dedicated MPE"
            } else if chordBank.customScale?.isMicrotonal == true && selected.sendsMIDI {
                chordStatus += " · MIDI 12-TET approximation"
            }
        } catch {
            // MIDI setup can succeed before acquiring a shared haptic lease.
            // Roll back this source only, including partially sent selectors.
            disarmChordPads()
            chordStatus = chordOutstanding.isEmpty && chordMPESelectors.isEmpty
                ? error.localizedDescription
                : "MIDI cleanup failed. Reset the DAW and retry Release All."
        }
    }

    private static func readChordProgression() -> ChordProgression {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.chordProgression.v1"),
              let archive = try? WorkspaceArchive.decode(ChordProgression.self, from: data),
              archive.payload.isValid else { return ChordProgression() }
        return archive.payload
    }

    func updateChordProgression(_ proposed: ChordProgression) {
        guard !progressionRunning, proposed.isValid else { return }
        chordProgression = proposed
        if let data = try? WorkspaceArchive.encode(name: "Chord progression", payload: proposed) {
            UserDefaults.standard.set(data, forKey: "TIHULU.chordProgression.v1")
        }
    }

    func startChordProgression(singleSlot: Int? = nil) {
        var settings = chordProgression
        if let singleSlot {
            guard settings.arpeggio != nil, (0..<ChordBank.padCount).contains(singleSlot) else { return }
            settings.slots = [singleSlot]
        }
        guard chordArmed, !progressionRunning,
              let plan = settings.plan(bank: chordBank, bpm: bpm) else {
            chordStatus = "Arm output and choose a valid non-empty progression and tempo."
            return
        }
        releaseChordPads()
        guard chordArmed else { return }
        let token = UUID()
        progressionToken = token
        progressionRunning = true
        progressionSingleSlot = singleSlot
        progressionTask = Task { [weak self] in
            let clock = ContinuousClock()
            let period = Duration.nanoseconds(Int64((plan.duration * 1_000_000_000).rounded()))
            var origin = clock.now
            do {
                repeat {
                    for step in plan.steps {
                        let onset = origin.advanced(by: .nanoseconds(Int64((step.onset * 1_000_000_000).rounded())))
                        let end = onset.advanced(by: .nanoseconds(Int64((step.gate * 1_000_000_000).rounded())))
                        try await clock.sleep(until: onset)
                        guard !Task.isCancelled, self?.progressionToken == token,
                              self?.chordArmed == true else { return }
                        if self?.progressionStep != step.position { self?.progressionStep = step.position }
                        // Skip an expired gate instead of bursting missed notes.
                        guard let slot = step.slot, let pad = step.pad, clock.now < end else { continue }
                        guard self?.pressProgressionChord(slot: slot, pad: pad, plan: plan) == true else { return }
                        try await clock.sleep(until: end)
                        guard !Task.isCancelled, self?.progressionToken == token else { return }
                        self?.releaseChordPad(slot)
                        guard self?.progressionToken == token else { return }
                    }
                    let boundary = origin.advanced(by: period)
                    try await clock.sleep(until: boundary)
                    guard !Task.isCancelled, self?.progressionToken == token else { return }
                    origin = clock.now >= boundary.advanced(by: period) ? clock.now : boundary
                } while plan.loop
                self?.stopChordProgression()
            } catch {
                if self?.progressionToken == token { self?.stopChordProgression() }
            }
        }
    }

    private func pressProgressionChord(slot: Int, pad: ChordPad, plan: ChordProgressionPlan) -> Bool {
        guard chordArmed, progressionRunning else { return false }
        let commands = chordState.press(slot: slot, pad: pad, channel: plan.channel, velocity: plan.velocity)
        guard deliverChordCommands(commands) else { return false }
        chordActiveSlots = chordState.activeSlots
        updateChordHaptics(attack:commands.contains { $0.destination.kind == .note && $0.value > 0 })
        return true
    }

    func stopChordProgression() {
        guard progressionRunning else { return }
        releaseChordPads()
    }

    func releaseManualChordPadsOnDisappear() {
        // A deliberately started progression can accompany a different
        // instrument page; global focus loss still invokes Release All.
        if !progressionRunning { releaseChordPads() }
    }

    func triggerChordPad(_ slot: Int) {
        guard chordArmed, let pad = chordBank.pad(at: slot) else { return }
        if progressionRunning { stopChordProgression() }
        guard chordArmed else { return }
        if chordState.activeSlots.contains(slot) {
            releaseChordPad(slot)
            if chordBank.latch || !chordArmed { return }
        }
        let commands = chordState.press(slot: slot, pad: pad, channel: chordBank.channel - 1,
                                        velocity: chordBank.velocity)
        guard deliverChordCommands(commands) else { return }
        chordActiveSlots = chordState.activeSlots
        updateChordHaptics(attack:commands.contains { $0.destination.kind == .note && $0.value > 0 })
        if !chordBank.latch {
            let token = UUID()
            chordTimerTokens[slot] = token
            let duration = chordBank.gateMS
            chordTimers[slot] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
                guard let self, self.chordTimerTokens[slot] == token else { return }
                self.releaseChordPad(slot)
            }
        }
    }

    private func releaseChordPad(_ slot: Int) {
        chordTimers.removeValue(forKey: slot)?.cancel()
        chordTimerTokens.removeValue(forKey: slot)
        _ = deliverChordCommands(chordState.release(slot: slot))
        chordActiveSlots = chordState.activeSlots
        updateChordHaptics()
    }

    private func updateChordHaptics(attack:Bool = false) {
        guard chordOwnsHaptics else { return }
        let frame = NoteHapticRenderer.frame(notes: chordState.activeNotes, velocity: chordBank.velocity,
                                              centsByPitchClass: chordBank.centsByPitchClass)
        chordHaptics?.update(frame: frame, masterLevel: masterLevel,attack:attack)
    }

    private func deliverChordCommands(_ commands: [SensorCommand]) -> Bool {
        guard chordBank.effectiveOutput.sendsMIDI else { return true }
        for logical in commands {
            let routed: [SensorCommand]
            if chordMPEActive {
                guard let next = chordMPEState.route(logical, centsByPitchClass: chordBank.centsByPitchClass) else {
                    disarmChordPads()
                    chordStatus = "MPE note limit or invalid tuning. Output stopped; check the DAW."
                    return false
                }
                routed = next
            } else {
                routed = [logical]
            }
            for command in routed {
                let isNote = command.destination.kind == .note
                if isNote && command.value > 0 { chordOutstanding.insert(command.destination) }
                guard activeChordMIDIOutput.send(command) else {
                    disarmChordPads()
                    chordStatus = "MIDI delivery failed. Check the DAW; note release is not confirmed."
                    return false
                }
                if isNote && command.value == 0 { chordOutstanding.remove(command.destination) }
            }
        }
        return true
    }

    func releaseChordPads() {
        progressionToken = nil
        progressionTask?.cancel()
        progressionTask = nil
        progressionRunning = false
        progressionStep = nil
        progressionSingleSlot = nil
        for task in chordTimers.values { task.cancel() }
        chordTimers.removeAll()
        chordTimerTokens.removeAll()
        _ = chordState.releaseAll()
        chordActiveSlots = []
        chordHaptics?.update(frame: nil, masterLevel: 0,discardPendingAttacks:true)
        // Retry all possibly transmitted notes, including a failed Note On.
        for key in Array(chordOutstanding) {
            if activeChordMIDIOutput.send(.init(key, value: 0)) { chordOutstanding.remove(key) }
        }
        if chordOutstanding.isEmpty { chordMPEState.clearAfterRelease() }
        // The original MPE endpoint is retained independently of bank selection.
        let selectorsReleased = chordMPESelectors.releaseAll(send:{ chordMPEOutput.send($0) })
        if !chordOutstanding.isEmpty || !selectorsReleased {
            chordHapticToken = nil
            chordHaptics?.stop()
            chordHaptics = nil
            releaseSharedOutputIfIdle()
            chordArmed = false
            chordStatus = "Some MIDI releases failed. Reset the receiving DAW and retry Release All."
        }
    }

    func disarmChordPads() {
        chordHapticToken = nil
        chordHaptics?.stop()
        chordHaptics = nil
        releaseSharedOutputIfIdle()
        releaseChordPads()
        chordArmed = false
        if chordOutstanding.isEmpty && chordMPESelectors.isEmpty { chordStatus = "Output off" }
    }

    private static func readSavedCaptureShortcut() -> PerformanceCaptureShortcut {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.captureShortcut"),
              let candidate = try? JSONDecoder().decode(PerformanceCaptureShortcut.self, from: data),
              candidate.isValid else { return .defaultShortcut }
        return candidate
    }

    private static func readTouchBarProfile() -> TouchBarProfile {
        guard let data = UserDefaults.standard.data(forKey: "TIHULU.touchBarProfile"),
              let profile = try? JSONDecoder().decode(TouchBarProfile.self, from: data)
        else { return TouchBarProfile() }
        return profile.normalized()
    }

    init() {
        prepareEngine()
    }

    /// Snapshot of the active standard melodic MIDI route. A copy is explicit;
    /// never guess a per-note MPE member or a percussion destination.
    var activeTouchControlChannel: Int? {
        guard touchRunning, touchMIDIOutEnabled, midiRunning, touchSeparateChannels == nil else { return nil }
        let surfaces = currentTouchConfiguration.selectedSurfaces.filter {
            currentTouchConfiguration.output(for: $0).sendsMIDI
        }
        return SurfaceMIDIChannel.controlTarget(
            base: touchMIDIChannel,
            hasMIDIDrums: surfaces.contains { currentTouchConfiguration.instrument(for: $0) == .drums },
            hasMIDIMelody: surfaces.contains { currentTouchConfiguration.instrument(for: $0) != .drums },
            isMPE: touchMIDIMode == .mpe
        )
    }

    func installTouchBar() {
        if touchBarBridge == nil {
            let bridge = StudioTouchBarBridge()
            bridge.controller = self
            touchBarBridge = bridge
        }
        touchBarBridge?.install(profile: touchBarProfile, builderToken: builderBarToken)
    }

    func attachNativeTouchBarToWindow() { touchBarBridge?.attachToKeyWindow() }

    func recordNativeTouchBarItemRequest() { nativeTouchBarItemRequests &+= 1 }
    func recordNativeTouchBarInput() { nativeTouchBarInputCount &+= 1 }

    /// Only the Touch Bar domain is retired; other instrument owners remain.
    func retireTouchBarGesturesForReplacement() {
        releaseTouchBarNotes()
        midi?.releaseTouchBarControls()
        touchBarSustainOn = false
        midi?.releaseTouchBarSustain()
    }

    /// Explicit reconnect releases the old bar owners before replacing controls.
    /// No note or MIDI output is armed by this action.
    func reconnectNativeTouchBar() {
        if groupNativeBar { stopGroupGamepads() }
        retireTouchBarGesturesForReplacement()
        if patchNativeBar { receiveBuilderScalar(.touchBar, value: nil) }
        nativeTouchBarItemRequests = 0
        nativeTouchBarInputCount = 0
        if touchBarBridge == nil { installTouchBar() }
        else { touchBarBridge?.install(profile: touchBarProfile, builderToken: builderBarToken, force: true) }
    }

    func setTouchBarProfile(_ proposed: TouchBarProfile) {
        guard !groupGamepadsRunning else { lastError = "Stop group MIDI before changing Touch Bar layout."; return }
        let next = proposed.normalized()
        guard next != touchBarProfile else { return }
        // Stop the old producer before replacing its target or channel.
        if liveHingeEnabled { enableLiveHinge(false) }
        disarmTouchBarOutput()
        if touchBarProfile.zones.contains(.chords) && !next.zones.contains(.chords) {
            releaseChordPads()
        }
        releaseTouchBarNotes()
        midi?.releaseTouchBarControls()
        if touchBarSustainOn {
            touchBarSustainOn = false
            midi?.releaseTouchBarSustain()
        }
        touchBarProfile = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "TIHULU.touchBarProfile")
        }
        touchBarBridge?.install(profile: next, builderToken: builderBarToken)
    }

    func releaseTouchBarNotes() {
        touchBarGestureEpoch.invalidate()
        nativePianoTokens.removeAll()
        releaseOptionalTouchBarNotes()
        for command in midiTouchBarNotes.reset(channel:touchBarProfile.channel) {
            midi?.sendPerformanceNote(note:command.destination.number,velocity:0,isOn:false,channel:command.destination.channel)
        }
    }

    func touchBarKey(_ note: Int, pressed: Bool, owner: TouchBarNoteOwner = .screenPiano) {
        guard !groupGamepadsRunning else { return }
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed else { return }
            let commands = touchBarLocalState.key(note, owner: owner, pressed: pressed,
                channel: touchBarProfile.channel, velocity: touchBarProfile.noteVelocity)
            if deliverTouchBarCommands(commands) {
                updateTouchBarHaptics(attack:commands.contains { $0.destination.kind == .note && $0.value > 0 })
            }
            return
        }
        cancelStartupGreeting()
        if !midiRunning && pressed { startMIDI() }
        guard midiRunning else { return }
        let safeNote = max(0, min(127, note))
        let commands = midiTouchBarNotes.key(safeNote,owner:owner,pressed:pressed,
            channel:touchBarProfile.channel,velocity:touchBarProfile.noteVelocity)
        for command in commands {
            midi?.sendPerformanceNote(note:command.destination.number,velocity:command.value,
                                      isOn:command.value>0,channel:command.destination.channel)
        }
    }

    func touchBarValue(_ zone: TouchBarZone, normalized value: Double, releaseOnly: Bool = false) {
        guard !groupGamepadsRunning else { return }
        guard value.isFinite, [.pitchBend, .fretless, .vibrato, .expression, .filter, .wah].contains(zone) else { return }
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed, value.isFinite else { return }
            let safe = min(1, max(0, value))
            let channel = touchBarProfile.channel
            var commands: [SensorCommand] = []
            switch zone {
            case .pitchBend, .fretless:
                touchBarLocalState.setBend(safe)
                commands = [.init(.init(.pitchBend, channel: channel), value: Int((safe * 16383).rounded()))]
            case .expression:
                touchBarLocalState.setExpression(safe)
                commands = [.init(.init(.controlChange, channel: channel, number: 11), value: Int((safe * 127).rounded()))]
            case .vibrato, .filter, .wah:
                if zone == .wah && !touchBarProfile.effectiveOutput.sendsMIDI { return }
                let cc = zone == .vibrato ? 1 : (zone == .wah ? 4 : 74)
                commands = [.init(.init(.controlChange, channel: channel, number: cc), value: Int((safe * 127).rounded()))]
            case .keys, .chords, .sustain: break
            }
            if deliverTouchBarCommands(commands) { updateTouchBarHaptics() }
            return
        }
        guard LegacyRecoveryPolicy.permitsControlEvent(running:midiRunning,releaseOnly:releaseOnly) else { return }
        cancelStartupGreeting()
        if !midiRunning { startMIDI() }
        guard midiRunning else { return }
        let safe = max(0, min(1, value))
        let channel = touchBarProfile.channel
        switch zone {
        case .pitchBend, .fretless:
            midi?.sendTouchBarControl(.init(.pitchBend,channel:channel),
                value:Int((8192+(safe-0.5)*2*8191).rounded()),bendRange:helperPitchBendRange)
        case .vibrato:
            midi?.sendTouchBarControl(.init(.controlChange,channel:channel,number:1),value:Int((safe*127).rounded()))
        case .expression:
            midi?.sendTouchBarControl(.init(.controlChange,channel:channel,number:11),value:Int((safe*127).rounded()))
        case .filter:
            midi?.sendTouchBarControl(.init(.controlChange,channel:channel,number:74),value:Int((safe*127).rounded()))
        case .wah:
            midi?.sendTouchBarControl(.init(.controlChange,channel:channel,number:4),value:Int((safe*127).rounded()))
        case .keys, .chords, .sustain:
            break
        }
    }

    func touchBarSustainPressed(_ isPressed: Bool) {
        guard !groupGamepadsRunning else { return }
        if touchBarProfile.effectiveOutput.sendsHaptics {
            guard touchBarOutputArmed else { return }
            let next = touchBarProfile.sustainMode == .toggle
                ? (isPressed ? !touchBarLocalState.sustain : touchBarLocalState.sustain) : isPressed
            let commands = touchBarLocalState.setSustain(next, channel: touchBarProfile.channel,
                                                          velocity: touchBarProfile.noteVelocity)
            touchBarSustainOn = touchBarLocalState.sustain
            if deliverTouchBarCommands(commands) { updateTouchBarHaptics() }
            return
        }
        guard LegacyRecoveryPolicy.permitsSustainEvent(running:midiRunning,pressed:isPressed) else { return }
        cancelStartupGreeting()
        if !midiRunning { startMIDI() }
        guard midiRunning else { return }
        let next = touchBarProfile.sustainMode == .toggle
            ? (isPressed ? !touchBarSustainOn : touchBarSustainOn)
            : isPressed
        guard next != touchBarSustainOn else { return }
        touchBarSustainOn = next
        midi?.setTouchBarSustain(next,channel:touchBarProfile.channel)
    }

    func touchBarNativeTap(_ note: Int) {
        guard !groupGamepadsRunning else { return }
        guard !touchBarProfile.effectiveOutput.sendsHaptics || touchBarOutputArmed else { return }
        let token = UUID()
        nativePianoTokens[note] = token
        touchBarKey(note, pressed: true, owner: .nativePiano)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, self.nativePianoTokens[note] == token else { return }
            self.nativePianoTokens.removeValue(forKey: note)
            self.touchBarKey(note, pressed: false, owner: .nativePiano)
        }
    }

    func armTouchBarOutput() {
        guard !groupGamepadsRunning else { touchBarOutputStatus = "Stop group MIDI first."; return }
        guard touchBarProfile.effectiveOutput.sendsHaptics, !touchBarOutputArmed else { return }
        guard (gamepadHaptics == nil && !chordOwnsHaptics) || sharedNoteOutputEnabled,
              !speakerBusy, !touchRunning, !midiHelperRunning, !midiRunning,
              !isPlaying, !sequenceOwnsHaptics, !liveHingeEnabled, !captureArmed, !pointerCaptured else {
            touchBarOutputStatus = "Stop other haptic sessions and the MIDI bridge first."
            return
        }
        releaseOptionalTouchBarNotes()
        guard touchBarOutputLedger.isEmpty else {
            touchBarOutputStatus = "MIDI release failed. Reset the DAW and retry."
            return
        }
        cancelStartupGreeting()
        renderGeneration &+= 1
        playback?.stop(closeDriver: false)
        guard requireEngine(), let driver else {
            touchBarOutputStatus = "Force Touch output unavailable."
            return
        }
        do {
            if touchBarProfile.effectiveOutput.sendsMIDI {
                try touchBarDedicatedMIDI.open()
                let channel = touchBarProfile.channel
                // Track partial RPN setup separately from performance CCs.
                guard touchBarOutputLedger.configureBendRange(channel:channel, send:{ touchBarDedicatedMIDI.send($0) }) else {
                    releaseOptionalTouchBarNotes()
                    touchBarOutputStatus = touchBarOutputLedger.isEmpty
                        ? "Unable to configure dedicated MIDI output."
                        : "MIDI selector cleanup failed. Reset the DAW and retry."
                    return
                }
            }
            let output = makeLiveNoteOutput(driver: driver, source: .touchBar)
            touchBarHaptics = output
            let token = UUID()
            touchBarOutputToken = token
            try output.start { [weak self] message in
                Task { @MainActor in
                    guard let self, self.touchBarOutputToken == token else { return }
                    self.disarmTouchBarOutput()
                    self.touchBarOutputStatus = "Trackpad output failed: " + message
                }
            }
            touchBarOutputArmed = true
            touchBarOutputStatus = touchBarProfile.effectiveOutput.rawValue + (sharedNoteOutputEnabled ? " ready (shared experimental)" : " ready")
        } catch {
            // A failed haptic lease must not leave dedicated MIDI setup armed.
            disarmTouchBarOutput()
            touchBarOutputStatus = touchBarOutputLedger.isEmpty
                ? error.localizedDescription
                : "MIDI cleanup failed. Reset the DAW and retry."
        }
    }

    private func updateTouchBarHaptics(attack:Bool = false) {
        guard touchBarOutputArmed else { return }
        touchBarHaptics?.update(frame: touchBarLocalState.frame(velocity: touchBarProfile.noteVelocity),
                                masterLevel: masterLevel,attack:attack)
    }

    private func deliverTouchBarCommands(_ commands: [SensorCommand]) -> Bool {
        guard touchBarProfile.effectiveOutput.sendsMIDI else { return true }
        for command in commands {
            guard touchBarOutputLedger.deliver(command, send:{ touchBarDedicatedMIDI.send($0) }) else {
                disarmTouchBarOutput()
                touchBarOutputStatus = "MIDI delivery failed; check note and controller release in the DAW."
                return false
            }
        }
        return true
    }

    func releaseOptionalTouchBarNotes() {
        // Do not invalidate legacy MIDI tap timers when merely releasing the
        // optional output. Otherwise an app-focus change could strand a note.
        guard touchBarProfile.effectiveOutput.sendsHaptics || touchBarOutputArmed ||
              !touchBarOutputLedger.isEmpty else { return }
        if touchBarGestureEpoch.invalidateOptionalOutput(
            sendsHaptics: touchBarProfile.effectiveOutput.sendsHaptics, armed: touchBarOutputArmed
        ) {
            nativePianoTokens.removeAll()
        }
        let channel = touchBarProfile.channel
        _ = touchBarLocalState.reset(channel: channel)
        touchBarHaptics?.update(frame: nil, masterLevel: 0,discardPendingAttacks:true)
        if touchBarOutputArmed { touchBarSustainOn = false }
        let released = touchBarOutputLedger.releaseAll(send:{ touchBarDedicatedMIDI.send($0) })
        if !released {
            touchBarOutputToken = nil
            touchBarHaptics?.stop()
            touchBarHaptics = nil
            releaseSharedOutputIfIdle()
            touchBarOutputArmed = false
            touchBarOutputStatus = "Some MIDI note/controller releases failed; reset the receiving DAW and retry."
        }
    }

    func disarmTouchBarOutput() {
        touchBarOutputToken = nil
        touchBarHaptics?.stop()
        touchBarHaptics = nil
        releaseSharedOutputIfIdle()
        releaseOptionalTouchBarNotes()
        touchBarOutputArmed = false
        if touchBarOutputLedger.isEmpty { touchBarOutputStatus = "Optional Trackpad output off" }
    }

    /// An explicit read-only probe never routes a sample to MIDI or haptics.
    func probeLidSensor() {
        guard !liveHingeEnabled, patchHinge == nil, !groupGamepadsRunning else {
            hingeProbeStatus = "Stop live lid input before probing."
            return
        }
        let probe = MacBookHingeAngleSource()
        let found = probe.start()
        hingeProbeStatus = (found ? "Read-only probe succeeded · " : "Read-only probe failed · ") + probe.status
        probe.stop()
    }

    func enableLiveHinge(_ enable: Bool) {
        if enable && patchHinge != nil {
            hingeSensorStatus = "Stop Builder lid input before using independent Tilt."
            return
        }
        if enable && !allowLivePerformance() { return }
        if !enable {
            let wasLive = liveHingeEnabled || hingeSensor != nil
            hingeSensor?.stop()
            hingeSensor = nil
            liveHingeEnabled = false
            if wasLive,let neutral = touchBarProfile.neutralTilt {
                simulatedHingeAngle = neutral.angle
                touchBarValue(neutral.zone,normalized:neutral.value,releaseOnly:true)
            }
            hingeSensorStatus = "Hardware sensor OFF · manual simulator available"
            return
        }
        guard !liveHingeEnabled else { return }
        let sensor = MacBookHingeAngleSource()
        hingeSensor = sensor
        sensor.onAngle = { [weak self, weak sensor] degrees,_ in
            guard let self, let sensor, self.hingeSensor === sensor else { return }
            self.applySimulatedHingeAngle(degrees)
        }
        sensor.onLoss = { [weak self, weak sensor] reason in
            guard let self, let sensor, self.hingeSensor === sensor else { return }
            self.enableLiveHinge(false)
            self.hingeSensorStatus = reason
        }
        if sensor.start() {
            liveHingeEnabled = true
            hingeSensorStatus = "Live hardware angle sensor active · MIDI mappings enabled"
        } else {
            hingeSensor = nil
            hingeSensorStatus = sensor.status
            liveHingeEnabled = false
        }
    }

    func returnTiltToNeutral() {
        guard patchHinge == nil, let neutral = touchBarProfile.neutralTilt else { return }
        // Retire the live producer first so its next poll cannot overwrite
        // the neutral. Neutralization itself must not start a stopped bridge.
        let wasLive = liveHingeEnabled || hingeSensor != nil
        enableLiveHinge(false)
        if !wasLive {
            simulatedHingeAngle = neutral.angle
            touchBarValue(neutral.zone, normalized: neutral.value, releaseOnly: true)
        }
    }

    func applySimulatedHingeAngle(_ degrees: Double) {
        guard degrees.isFinite else { return }
        simulatedHingeAngle = min(175, max(5, degrees))
        guard patchHinge == nil else { return }
        guard let value = touchBarProfile.normalizedTilt(degrees) else { return }
        switch touchBarProfile.tiltTarget {
        case .disabled: break
        case .filter: touchBarValue(.filter, normalized: value)
        case .wah: touchBarValue(.wah, normalized: value)
        case .expression: touchBarValue(.expression, normalized: value)
        case .vibrato: touchBarValue(.vibrato, normalized: value)
        case .pitchBend: touchBarValue(.pitchBend, normalized: value)
        }
    }

    private func prepareEngine() {
        guard !engineReady, !speakerBusy else { return }
        // Reconnect must not discard possibly delivered MIDI state together
        // with the old endpoint. Retry its scoped cleanup before replacement.
        if let midi, midi.hasUnconfirmedOutgoingCleanup {
            midi.stop()
            guard !midi.hasUnconfirmedOutgoingCleanup else {
                engineStatus = "Stopped · MIDI cleanup unresolved"
                lastError = midi.requiresManualDAWReset
                    ? "Reset the DAW controllers, then quit and relaunch this app. Reconnect is blocked while MIDI state is uncertain."
                    : "MIDI release remains unconfirmed. Keep the receiving DAW available and retry Reconnect."
                return
            }
        }
        // Preserve audit evidence before retiring the measured endpoint.
        finishKeyboardAudit()
        // Only initialize after the previous session has been retired.
        engineGeneration &+= 1
        driver?.close()
        playback = nil
        touch = nil
        midi = nil
        systemAudio = nil
        driver = nil
        do {
            let driver = try HapticTrackpadDriver()
            try driver.open()
            self.driver = driver
            self.playback = HapticPlaybackEngine(driver: driver)
            let touchEngineGeneration = engineGeneration
            self.touch = TouchInstrumentService(driver:driver,onHapticFault:{ [weak self] message in
                Task { @MainActor in
                    guard let self,self.engineGeneration == touchEngineGeneration,self.touchRunning,
                          self.touch?.hapticDiagnosticSnapshot().outputFaulted == true else { return }
                    self.lastError = "Touch haptic output stopped after repeated motor failures. MIDI routing unchanged; Stop/Start Touch to retry. " + message
                }
            })
            self.midi = MIDIHapticService(driver: driver)
            self.systemAudio = SystemAudioHapticCapture(driver: driver)
            engineReady = true
            engineStatus = driver.isBuiltIn ? "Built-in Force Touch trackpad ready" : "External Force Touch trackpad ready"
            lastError = nil
        } catch {
            engineReady = false
            engineStatus = "Haptic engine unavailable"
            lastError = error.localizedDescription
        }
    }

    func panicStop() {
        // Free the pointer before potentially slow audio/MIDI cleanup.
        retireCaptureMonitor()
        captureArmed = false
        captureHotkeyArmed = false
        stopGroupGamepads()
        if !groupCleanupIDs.isEmpty || groupDisposalCount != 0 { retryGroupCleanup() }
        stopInstrumentPatch()
        stopLiveSequence()
        engineGeneration &+= 1
        disarmTouchBarOutput()
        disarmChordPads()
        sharedNoteOutput?.retire()
        sharedNoteOutput = nil
        sharedNoteOutputEnabled = false
        renderGeneration &+= 1
        cancelStartupGreeting()
        enableLiveHinge(false)
        midiSessionEpoch.end()
        midi?.stop()
        finishKeyboardAudit()
        releaseTouchBarNotes()
        touchBarSustainOn = false
        clickedSurface = nil
        trackpadClickPressure = nil
        stopSystemAudio()
        playback?.stop(closeDriver: false)
        surfaceInventoryTask?.cancel()
        surfaceInventoryTask = nil
        surfaceMonitorToken = nil
        surfaceInbox?.close()
        surfaceInbox = nil
        clearClickAttribution()
        touch?.stopPreview()
        // Terminal revocation drains an in-flight submission and blocks any
        // late producer or monitoring request on this exact driver instance.
        driver?.panicStop()
        isPlaying = false
        touchRunning = false
        touchPreviewRunning = false
        instrumentPreviewRequested = false
        helperPreviewRequested = false
        midiHelperRunning = false
        helperSustainState.reset()
        helperPedalPublicationFence.reset()
        helperEffectsPublicationFence.reset()
        touchSustainState.reset()
        touchSustainRearmGate.reset()
        touchInstrumentSustainActive = false
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        touchContact = TrackpadContact()
        touchStates = []
        midiHelperStates = []
        liveTouchStates = []
        liveHelperStates = []
        touchPreviewCadence.reset()
        helperPreviewCadence.reset()
        activeMIDINotes = []
        activeMIDINoteMap.removeAll()
        midiRunning = false
        systemAudioRunning = false
        pointerCaptured = false
        captureStatus = "Stopped · cursor released"
        engineReady = false
        engineStatus = "Stopped — press Reconnect to reopen the trackpad"
        if midi?.hasUnconfirmedOutgoingCleanup == true {
            lastError = midi?.requiresManualDAWReset == true
                ? "Reset DAW controllers and quit/relaunch this app."
                : "MIDI cleanup remains unconfirmed. Retry Reconnect to attempt scoped cleanup."
        }
    }

    func reconnect() {
        // Reconnect is an explicit session reset, never a silent hot swap.
        // Preserve user settings, but do not auto-resume active performances.
        panicStop()
        let generation = engineGeneration
        if speakerBusy {
            let pending = speakerTask
            engineStatus = "Stopping capture before reconnect"
            Task { [weak self] in
                await pending?.value
                guard let self, self.engineGeneration == generation else { return }
                self.prepareEngine()
            }
        } else {
            prepareEngine()
        }
    }

    /// Once per process, not on every SwiftUI appearance or reconnect.
    /// No non-Turkish fallback and no permission requests for the greeting.
    func playStartupGreetingOnce() {
        guard !startupGreetingAttempted else { return }
        startupGreetingAttempted = true
        guard engineReady, let engine = playback else { return }
        let message = Self.startupGreeting
        startupGreetingTask = Task { [weak self] in
            let events = try? await Task.detached(priority: .utility) { () throws -> [ScheduledHapticEvent] in
                let voices = VoiceHapticService.voiceOptions(language: .turkish)
                guard let voice = voices.first(where: { $0.id == "say:Yelda" })
                        ?? voices.first(where: { $0.backend == .say })
                        ?? voices.first(where: { $0.backend == .avSpeech }) else { return [] }
                return try VoiceHapticService.render(text: message, voice: voice.id)
            }.value
            guard !Task.isCancelled, let self, self.engineReady,
                  self.playback === engine, !self.isPlaying,
                  !self.touchRunning, !self.midiRunning, !self.midiHelperRunning,
                  !self.systemAudioRunning, !self.groupGamepadsRunning, !self.liveNoteOwnsHaptics, let events, !events.isEmpty else { return }
            self.startupGreetingPlaying = true
            let generation = self.renderGeneration
            engine.play(events: events, masterLevel: self.masterLevel) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.renderGeneration == generation else { return }
                    self.startupGreetingPlaying = false
                    self.startupGreetingTask = nil
                }
            }
        }
    }

    private func cancelStartupGreeting() {
        startupGreetingAttempted = true
        startupGreetingTask?.cancel()
        startupGreetingTask = nil
        if startupGreetingPlaying {
            playback?.stop(closeDriver: false)
            startupGreetingPlaying = false
        }
    }

    private func beginPlaybackRequest() -> UInt64 {
        renderGeneration &+= 1
        playback?.stop(closeDriver: false)
        isPlaying = true
        lastError = nil
        return renderGeneration
    }

    private func playRendered(_ events: [ScheduledHapticEvent], token: UInt64,
                              loop: Bool = false, duration: Double? = nil, level: Double? = nil) {
        guard renderGeneration == token, let playback else {
            if renderGeneration == token { isPlaying = false }
            return
        }
        playback.play(events: events, masterLevel: level ?? masterLevel,
                      loop: loop, duration: duration) { [weak self] error in
            Task { @MainActor in
                guard let self, self.renderGeneration == token else { return }
                self.isPlaying = false
                if let error {
                    self.lastError = error
                    self.engineStatus = "Playback error"
                }
            }
        }
    }

    func speak(_ text: String, voice: String?) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = beginPlaybackRequest()
        let renderText = text
        let renderVoice = voice
        let cancellation = VoiceRenderCancellation()
        voiceRenderCancellation = cancellation
        Task {
            defer {
                if voiceRenderCancellation === cancellation { voiceRenderCancellation = nil }
            }
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try VoiceHapticService.render(text:renderText,voice:renderVoice,cancellation:cancellation)
                }.value
                guard renderGeneration == token, !liveNoteOwnsHaptics else { return }
                playRendered(events, token: token)
            } catch {
                guard renderGeneration == token else { return }
                fail(error)
            }
        }
    }

    /// One independent MIDI sequence, with optional exclusive haptic
    /// preview. MIDI-only does not require the Force Touch driver.
    func startLiveSequence(output: MusicalOutput, loop: Bool, tuned:TunedMIDIClip? = nil, makeClip: () throws -> MIDIClip) {
        guard !groupGamepadsRunning else { sequenceStatus = "Stop group MIDI first."; return }
        guard output.sendsMIDI, !sequenceRunning, tuned == nil || !output.sendsHaptics else { return }
        do {
            let clip = try (tuned?.clip ?? makeClip()).validated()
            let schedule = try MIDIClipSchedule(clip)
            let hapticEvents = output.sendsHaptics ? try clip.grooveHapticEvents() : []
            if output.sendsHaptics {
                guard allowOtherPerformance(), !isPlaying, !touchRunning, !midiRunning,
                      !midiHelperRunning, !liveHingeEnabled else {
                    sequenceStatus = "Stop other haptic performances before choosing Both."
                    return
                }
                cancelStartupGreeting()
                guard requireEngine(), playback != nil else { return }
            }
            guard releaseSequenceOutput() else {
                sequenceStatus = "MIDI release failed. Reset the receiving DAW and retry Stop."
                return
            }
            sequenceUsesTuning = tuned != nil
            let port = activeSequenceMIDI
            try port.open()
            if let tuned {
                guard sequenceSelectors.configure(tuned.setupCommands,send:{ port.send($0) }) else {
                    stopLiveSequence()
                    sequenceStatus = "MPE setup failed. Check DAW and retry Stop before playback."
                    return
                }
            }
            let token = UUID()
            sequenceToken = token
            sequenceRunning = true
            sequenceOwnsHaptics = output.sendsHaptics
            sequenceStatus = (sequenceUsesTuning ? "Playing · TIHULU Tuned Sequencer MPE · " : "Playing · TIHULU Sequencer · ") + output.rawValue
            if output.sendsHaptics {
                renderGeneration &+= 1
                isPlaying = true
                playback?.play(events: hapticEvents, masterLevel: masterLevel, loop: loop,
                               duration: schedule.seconds(at: schedule.length)) { [weak self] error in
                    if let error {
                        Task { @MainActor in
                            guard let self, self.sequenceToken == token else { return }
                            self.stopLiveSequence()
                            self.lastError = error
                        }
                    }
                }
            }
            sequenceTask = Task { [weak self] in
                let clock = ContinuousClock()
                func offset(_ tick: Int) -> Duration {
                    .nanoseconds(Int64((schedule.seconds(at: tick) * 1_000_000_000).rounded()))
                }
                let period = offset(schedule.length)
                var origin = clock.now
                do {
                    repeat {
                        for event in schedule.events {
                            try await clock.sleep(until: origin.advanced(by: offset(event.tick)))
                            guard !Task.isCancelled, let self, self.sequenceToken == token else { return }
                            // Skip notes whose entire gate has expired.
                            if event.isNoteOn && clock.now >= origin.advanced(by: offset(event.endTick)) { continue }
                            let delivered = self.sequenceLedger.deliver(event.command, send: { port.send($0) })
                            guard delivered else {
                                self.stopLiveSequence()
                                self.lastError = "Sequencer MIDI delivery failed. Check the receiving DAW."
                                return
                            }
                        }
                        let boundary = origin.advanced(by: period)
                        try await clock.sleep(until: boundary)
                        guard !Task.isCancelled, self?.sequenceToken == token else { return }
                        // When substantially stalled, never burst old cycles.
                        origin = clock.now >= boundary.advanced(by: period) ? clock.now : boundary
                    } while loop
                    self?.stopLiveSequence()
                } catch {
                    if self?.sequenceToken == token { self?.stopLiveSequence() }
                }
            }
        } catch {
            sequenceStatus = error.localizedDescription
        }
    }

    func stopLiveSequence() {
        sequenceToken = nil
        sequenceTask?.cancel()
        sequenceTask = nil
        if sequenceOwnsHaptics {
            renderGeneration &+= 1
            playback?.stop(closeDriver: false)
            isPlaying = false
        }
        sequenceOwnsHaptics = false
        sequenceRunning = false
        let released = releaseSequenceOutput()
        sequenceStatus = released ? "Sequencer MIDI idle" : "MIDI release failed. Reset the receiving DAW and retry Stop."
    }

    func playGrooveClip(loop: Bool, makeClip: () throws -> MIDIClip) {
        guard allowRenderedPerformance() else { return }
        guard !touchRunning, !midiRunning, !midiHelperRunning, !liveHingeEnabled else {
            lastError = "Stop other live performances before starting groove haptic playback."
            return
        }
        do {
            let clip = try makeClip()
            let events = try clip.grooveHapticEvents()
            cancelStartupGreeting()
            guard requireEngine() else { return }
            let token = beginPlaybackRequest()
            playRendered(events, token: token, loop: loop,
                         duration: Double(clip.length) * 60 / clip.bpm / Double(MIDIClip.ppq))
        } catch {
            // Validation before taking over the current playback.
            lastError = error.localizedDescription
        }
    }

    func playNotes(_ steps: [NoteStep], length: Int = 16, loop: Bool = false) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard let duration = PlaybackTimeline.patternDuration(bpm: bpm, stepsPerBeat: 4, length: length) else {
            lastError = "Invalid sequence tempo or length."
            return
        }
        let token = beginPlaybackRequest()
        do {
            let events = try HapticPatternRenderer.notes(.init(bpm: bpm, stepsPerBeat: 4, length: length, steps: steps))
            playRendered(events, token: token, loop: loop, duration: duration)
        } catch { fail(error) }
    }

    func playDrums(_ hits: [DrumStep], length: Int = 16, loop: Bool = false) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard let duration = PlaybackTimeline.patternDuration(bpm: bpm, stepsPerBeat: 4, length: length) else {
            lastError = "Invalid sequence tempo or length."
            return
        }
        let token = beginPlaybackRequest()
        let events = HapticPatternRenderer.drums(.init(bpm: bpm, stepsPerBeat: 4, length: length, hits: hits))
        playRendered(events, token: token, loop: loop, duration: duration)
    }

    func stopPlayback() {
        stopLiveSequence()
        stopRenderedPlayback()
    }

    /// Voice/audio Stop must not terminate an independent MIDI sequence.
    /// Combined sequencer output is stopped through its own owner.
    func stopRenderedPlayback() {
        guard !sequenceOwnsHaptics else { return }
        let needsStop = renderedOutputPolicy.needsRenderedStop
        renderGeneration &+= 1
        cancelStartupGreeting()
        if needsStop { playback?.stop(closeDriver: false) }
        isPlaying = false
    }

    func testTone(frequency: Double) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        guard frequency.isFinite, frequency > 0 else { return }
        let duration = max(2, (0.04 * frequency).rounded()) / frequency * 1_000
        let token = beginPlaybackRequest()
        playRendered([.init(time: 0, frame: .init(tones: [.init(frequencyHz: frequency)],
                       durationMS: duration, level: masterLevel))], token: token, level: 1)
    }

    func sweep() {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        var events: [ScheduledHapticEvent] = []
        let duration = 5.0
        let step = 0.012
        var time = 0.0
        while time < duration {
            let frequency = 100 * pow(40, time / duration)
            events.append(.init(time: time, frame: .init(
                tones: [.init(frequencyHz: frequency)], durationMS: step * 1_000, level: masterLevel
            )))
            time += step
        }
        let token = beginPlaybackRequest()
        playRendered(events, token: token, level: 1)
    }

    var touchSessionSummary: String {
        guard touchRunning else { return "Melodic notes or drums; independent surface outputs" }
        return currentTouchConfiguration.surfaceSelection.rawValue + " · " +
            (currentTouchConfiguration.fretless ? "Fretless" : "Fretted / drums")
    }

    var helperSessionSummary: String {
        guard midiHelperRunning else { return "Pitch bend, vibrato, expression and sustain" }
        return helperSurfaceSelection.rawValue + " · MIDI channel " + String(helperTargetChannel + 1)
    }

    func setMagicMouseOrientation(_ newOrientation: SurfaceOrientation) {
        guard magicMouseOrientation != newOrientation else { return }
        // Coordinates are transformed at Helper admission. Do not apply a
        // pre-orientation queued contact to a new expressive mapping.
        if midiHelperRunning && helperSurfaceSelection.accepts(.magicMouse) {
            helperEffectsPublicationFence.begin(after:touch?.consumerPublicationBoundary().sequence ?? 0)
            helperEffectsRearmGate.invalidate()
            if helperSendToDAW {
                midi?.resetHelperControls(assignments:helperAssignments,channel:helperTargetChannel,
                    vibratoCC:helperVibratoCC,expressionCC:helperExpressionCC)
            }
        }
        magicMouseOrientation = newOrientation
        UserDefaults.standard.set(newOrientation.rawValue, forKey: "TIHULU.magicMouseOrientation")
        var updated = currentTouchConfiguration
        updated.magicMouseOrientation = newOrientation
        updateTouchConfiguration(updated)
    }

    /// Only one native MultitouchSupport callback can be registered per device.
    /// Distribute the same physical frames to independently enabled Instrument
    /// and Helper consumers, filtered by surface assignment.
    private func refreshSharedSurfaceMonitoring() {
        guard !handlingSurfaceInventoryFault,let touch else { return }
        let needed = instrumentPreviewRequested || helperPreviewRequested ||
                     touchRunning || midiHelperRunning || groupSurfaceMailbox != nil ||
                     (patchPhysical && instrumentPatch.routes.contains { $0.source != patchHybridSource && ($0.source == .trackpad || $0.source == .magicMouse) })
        if !needed {
            surfaceInventoryTask?.cancel()
            surfaceInventoryTask = nil
            surfaceMonitorToken = nil
            surfaceInbox?.close()
            surfaceInbox = nil
            clearClickAttribution()
            touch.stopPreview()
            touchPreviewRunning = false
            return
        }

        var monitoringConfiguration = currentTouchConfiguration
        monitoringConfiguration.surfaceSelection = .both
        monitoringConfiguration.magicMouseOrientation = magicMouseOrientation
        // A Helper-only surface must not accidentally produce Instrument
        // haptics, even when the Instrument is playing on the other surface.
        if !currentTouchConfiguration.surfaceSelection.accepts(.trackpad) {
            monitoringConfiguration.trackpadOutput = .midiInstrument
        }
        if !currentTouchConfiguration.surfaceSelection.accepts(.magicMouse) {
            monitoringConfiguration.magicMouseOutput = .midiInstrument
        }

        if touchPreviewRunning {
            touch.update(configuration: monitoringConfiguration)
            return
        }

        do {
            let generation = engineGeneration
            let token = UUID()
            surfaceMonitorToken = token
            let inbox = OrderedTouchInbox<QueuedTouchSnapshot>()
            surfaceInbox?.close()
            surfaceInbox = inbox
            surfaceSnapshotCursor.reset()
            touchDispatchMetrics = TouchDispatchMetrics()
            touchPreviewCadence.reset()
            helperPreviewCadence.reset()
            liveTouchStates = []
            liveHelperStates = []
            clearClickAttribution()
            try touch.startQueuedPreview(configuration: monitoringConfiguration, inbox:inbox) { [weak self, weak inbox] in
                Task { @MainActor in
                    guard let self, let inbox else { return }
                    self.drainTouchInbox(inbox,generation:generation,token:token)
                }
            }
            touchPreviewRunning = true
            startSurfaceInventoryCheck(generation:generation,token:token)
        } catch {
            surfaceInventoryTask?.cancel()
            surfaceInventoryTask = nil
            surfaceMonitorToken = nil
            surfaceInbox?.close()
            surfaceInbox = nil
            clearClickAttribution()
            touchPreviewRunning = false
            fail(error)
        }
    }

    private func missingNativeSurfaceMessage(_ required:Set<TouchSurfaceKind>) -> String? {
        let missing = NativeSurfaceAdmission.missing(required:required,registered:driver?.registeredSurfaceKinds)
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.rawValue).sorted().joined(separator:", ")
        return "Native surface unavailable: " + names + ". Connect the device and reopen surface monitoring (or Reconnect), then Start explicitly."
    }

    private func nativeSurfaces(for sources:Set<SensorSource>) -> Set<TouchSurfaceKind> {
        var required:Set<TouchSurfaceKind> = []
        if sources.contains(.trackpad) { required.insert(.trackpad) }
        if sources.contains(.magicMouse) { required.insert(.magicMouse) }
        return required
    }

    private func startSurfaceInventoryCheck(generation:UInt64,token:UUID) {
        surfaceInventoryTask?.cancel()
        guard let driver else { return }
        let expected=driver.registeredSurfaceIDs
        let results=NativeInventoryResultSlot<HapticTrackpadDriver.SurfaceInventory>()
        driver.requestSurfaceInventory(results)
        surfaceInventoryTask = Task { [weak self,driver,results] in
            var evidence = NativeSurfaceInventoryGuard()
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self,self.engineGeneration == generation,
                      self.surfaceMonitorToken == token,self.touchPreviewRunning else { return }
                let inventory=results.take()
                let available=inventory?.expected == expected ? inventory?.available : nil
                switch evidence.observe(expected:expected,available:available) {
                case .healthy,.suspect:
                    driver.requestSurfaceInventory(results)
                case .lost,.unavailable:
                    self.handleSurfaceInventoryFault()
                    return
                }
            }
        }
    }

    private func handleSurfaceInventoryFault() {
        guard !handlingSurfaceInventoryFault else { return }
        handlingSurfaceInventoryFault = true
        defer { handlingSurfaceInventoryFault = false }
        // Release the cursor and retire publication before MIDI cleanup.
        // Unrelated group sources, audio and sequencers are not panicked.
        retireCaptureMonitor()
        captureArmed = false
        captureHotkeyArmed = false
        surfaceInventoryTask?.cancel()
        surfaceInventoryTask = nil
        surfaceMonitorToken = nil
        surfaceInbox?.close()
        surfaceInbox = nil
        clearClickAttribution()
        instrumentPreviewRequested = false
        helperPreviewRequested = false
        if touchRunning { stopTouch() }
        if midiHelperRunning { stopMIDIHelper() }
        if let run = groupRunToken,groupSurfaceMailbox != nil {
            retireGroupSurfaces([.trackpad,.magicMouse],
                reason:"Native surface inventory lost. Surface owners released; restart explicitly.",run:run)
        }
        if patchPhysical && instrumentPatch.routes.contains(where: {
            $0.source != patchHybridSource && ($0.source == .trackpad || $0.source == .magicMouse)
        }) { stopInstrumentPatch() }
        touch?.stopPreview()
        touchPreviewRunning = false
        liveTouchStates = []
        liveHelperStates = []
        touchStates = []
        midiHelperStates = []
        touchContact = TrackpadContact()
        captureStatus = "Cursor free · native surface inventory lost"
        lastError = "Native touch device disconnected or inventory unavailable. Surface performances stopped; reconnect devices and restart explicitly."
    }

    private func drainTouchInbox(_ inbox: OrderedTouchInbox<QueuedTouchSnapshot>, generation: UInt64, token: UUID) {
        guard engineGeneration == generation, surfaceMonitorToken == token,
              surfaceInbox === inbox, touchPreviewRunning else { return }
        let batch = inbox.take()
        if batch.overflow {
            handleTouchInputBacklog()
            return
        }
        for sample in batch.samples {
            guard surfaceMonitorToken == token, surfaceInbox === inbox, touchPreviewRunning else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            guard let revision = touch?.currentSampleRevision,
                  surfaceSnapshotCursor.accept(sample.stamp) else {
                touchDispatchMetrics.reject()
                continue
            }
            let mappedCurrent = sample.stamp.revision == revision
            let helperNeeded = (helperPreviewRequested || midiHelperRunning) && helperSurfaceSelection.accepts(sample.sourceSurface)
            // Old note maps cannot sound, but their ordered physical
            // releases still belong to an independently running Helper.
            guard mappedCurrent || helperNeeded else {
                touchDispatchMetrics.reject()
                continue
            }
            // Never replay a late musical onset after a blocked main actor.
            if !TouchPublicationAdmission.permits(queuedAt:sample.queuedAt,now:startedAt) {
                touchDispatchMetrics.reject()
                if touchRunning || midiHelperRunning {
                    handleTouchInputBacklog()
                    // A partial drain still owns the next scheduling turn.
                    if batch.more {
                        Task { @MainActor [weak self, weak inbox] in
                            guard let self, let inbox else { return }
                            self.drainTouchInbox(inbox,generation:generation,token:token)
                        }
                    }
                    return
                }
                continue
            }
            if mappedCurrent {
                clickTouchingSurfaces = Set(sample.helperContacts.map(\.surface))
                clickSnapshotRevision = sample.clickObservation?.stamp.revision
                clickSnapshotReceivedAt = sample.clickObservation?.receivedAt
            }
            guard handleSharedSurfaceStates(sample,admitTouch:mappedCurrent,startedAt:startedAt) else {
                touchDispatchMetrics.reject()
                if touchRunning || midiHelperRunning {
                    handleTouchInputBacklog()
                    if batch.more {
                        Task { @MainActor [weak self, weak inbox] in
                            guard let self, let inbox else { return }
                            self.drainTouchInbox(inbox,generation:generation,token:token)
                        }
                    }
                    return
                }
                continue
            }
            touchDispatchMetrics.record(queuedAt:sample.queuedAt,startedAt:startedAt,
                endedAt:ProcessInfo.processInfo.systemUptime)
        }
        if batch.more {
            Task { @MainActor [weak self, weak inbox] in
                guard let self, let inbox else { return }
                self.drainTouchInbox(inbox,generation:generation,token:token)
            }
        }
    }

    private func handleTouchInputBacklog() {
        // A missing release is a fault, not permission to replay stale notes.
        let wasPlaying = touchRunning || midiHelperRunning
        touch?.invalidatePendingSamples()
        clearClickAttribution()
        if touchRunning { stopTouch() }
        if midiHelperRunning { stopMIDIHelper() }
        liveTouchStates = []
        liveHelperStates = []
        touchStates = []
        midiHelperStates = []
        touchContact = TrackpadContact()
        if wasPlaying {
            lastError = "Touch input backlog. Touch Instrument and Helper stopped; restart explicitly."
        }
    }

    private func handleSharedSurfaceStates(_ sample:QueuedTouchSnapshot,admitTouch:Bool,startedAt:Double) -> Bool {
        let instrumentStates = admitTouch && (instrumentPreviewRequested || touchRunning) ? sample.states.filter {
            currentTouchConfiguration.surfaceSelection.accepts($0.surface)
        } : nil
        let helperStates = (helperPreviewRequested || midiHelperRunning) ? sample.helperContacts.filter {
            helperSurfaceSelection.accepts($0.surface)
        }.map { $0.oriented(magicMouseOrientation) } : nil
        // Commit both pedal intents before any note release. An owner
        // handoff in one frame must not pulse CC64 off and back on.
        let selectedSource = helperSurfaceSelection.accepts(sample.sourceSurface)
        let pedalAdmitted = helperPedalPublicationFence.permits(sample.stamp,selectedSource:selectedSource)
        let effectsAdmitted = helperEffectsPublicationFence.permits(sample.stamp,selectedSource:selectedSource)
        var pedal:MIDIHelperSustainSnapshot?
        var fence=PhysicalReceiptSendFence(receipt:sample.queuedAt,maximumAge:TouchPublicationAdmission.maximumAge,initialNow:startedAt)
        let admit:()->Bool = { fence.permits(now:ProcessInfo.processInfo.systemUptime) }
        return TouchPublicationAdmission.dispatch(permits:admit,
            prepare:{
                pedal = applyPhysicalPedalFrame(touchStates:instrumentStates,
                    helperStates:pedalAdmitted ? helperStates : nil,freshFrame:true,admitOnset:admit)
            },touch:{
                if let instrumentStates { handleTouchStates(instrumentStates,pedal:pedal,admitOnset:admit) }
            },helper:{
                if let helperStates {
                    handleMIDIHelperStates(helperStates,pedalAdmitted:pedalAdmitted,effectsAdmitted:effectsAdmitted,admitOnset:admit)
                }
            })
    }

    /// Explicitly copy the current bank scale. Live performances never retune
    /// as a side effect of editing the bank on another page.
    func useChordBankScaleForTouch() {
        guard !touchRunning else { return }
        var scale = chordBank.customScale ?? CustomScale()
        if chordBank.customScale == nil {
            scale.name = chordBank.scale.rawValue
            scale.intervals = chordBank.scale.intervals
        }
        guard scale.isValid else { return }
        touchCustomScale = scale
    }

    func clearTouchCustomScale() {
        guard !touchRunning else { return }
        touchCustomScale = nil
    }

    func startTouchPreview(configuration: TouchInstrumentConfiguration) {
        guard requireEngine() else { return }
        // Reopening the view never overwrites an already running performance
        // with fresh @State defaults from a newly constructed SwiftUI view.
        if touchRunning {
            instrumentPreviewRequested = true
            refreshSharedSurfaceMonitoring()
            return
        }
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        currentTouchConfiguration = configuration
        instrumentPreviewRequested = true
        refreshSharedSurfaceMonitoring()
        if !touchRunning && !midiHelperRunning {
            engineStatus = "Touch preview active · no MIDI or haptic output until Start"
        }
    }

    func updateTouchConfiguration(_ configuration: TouchInstrumentConfiguration) {
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        if touchRunning {
            configuration = currentTouchConfiguration.applyingLiveControls(from:configuration)
            guard configuration.hasValidSampleDomain else {
                stopTouch()
                lastError = "Invalid live Touch configuration. Performance stopped; correct the settings and restart."
                return
            }
            guard configuration != currentTouchConfiguration else { return }
            if configuration.requiresSampleInvalidation(comparedTo:currentTouchConfiguration) {
                // Match the native service's sample/haptic reset at the
                // controller boundary. Do not wait for another hardware
                // frame to release notes belonging to the old mapping.
                touch?.invalidatePendingSamples()
                touchClickFence.begin(now:ProcessInfo.processInfo.systemUptime)
                liveTouchStates = []
                touchSustainRearmGate.invalidate()
                touchSustainState.reset()
                midi?.releaseTouchSustain()
                midi?.endAllTouchOutput()
                touch?.setSustainActive(false)
                touchInstrumentSustainActive = false
            }
        }
        currentTouchConfiguration = configuration
        refreshSharedSurfaceMonitoring()
    }

    func stopTouchPreview() {
        // Navigation drops only the UI preview request, never a live session.
        instrumentPreviewRequested = false
        touchPreviewCadence.reset()
        if !touchStates.isEmpty { touchStates = [] }
        if touchContact.isDown { touchContact = TrackpadContact() }
        guard !touchRunning else { return }
        liveTouchStates = []
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        midi?.endAllTouchOutput()
        touchStates = []
        touchContact = TrackpadContact()
        refreshSharedSurfaceMonitoring()
        if !midiHelperRunning { engineStatus = engineReady ? "Force Touch trackpad ready" : engineStatus }
        stopCaptureMonitorIfIdle()
    }

    func startTouch(
        configuration: TouchInstrumentConfiguration,
        midiOut: Bool,
        midiMode: TouchMIDIMode = .standard,
        multiTouch: Bool = true,
        midiChannel: Int = 0,
        separateChannels: DAWSurfaceChannels? = nil,
        independentDAWSustain: Bool = false,
        sustainSettings: MIDIHelperSustainSettings = .init()
    ) {
        guard !touchRunning, allowLivePerformance() else { return }
        guard configuration.hasValidSampleDomain else {
            lastError = "Invalid Touch configuration. Check root, note width, pitch span, trigger threshold and gain."
            return
        }
        if separateChannels != nil {
            guard midiOut, midiMode == .standard, configuration.permitsSeparateDAWSurfaceChannels else {
                lastError = "Separate DAW channels require two pitched Standard MIDI surfaces. Disable MPE/fretless or use the shared route."
                return
            }
        }
        guard !midiOut || midiMode == .mpe || !configuration.requiresPolyphonicFretlessMPE(multiTouch:multiTouch) else {
            lastError = "Fretless Multi Touch MIDI needs MPE. Select MPE for independent fingers, or turn Multi Touch off for Standard MIDI."
            return
        }
        guard configuration.permitsStringMIDI(isMPE:midiMode == .mpe) else {
            lastError = "Fretless and microtonal String MIDI require MPE. Fretted strings cannot share Standard MIDI with a fretless melodic surface. Check the string layout and select MPE or separate routes."
            return
        }
        guard configuration.permitsPhysicalChordMIDI(isMPE:midiMode == .mpe) else {
            lastError = "Physical chord MIDI requires Standard mode, no shared fretless MIDI, and explicit approximation for microtonal banks."
            return
        }
        guard configuration.permitsMelodicMIDI(isMPE:midiMode == .mpe) else {
            lastError = "Custom cent offsets require MPE, Trackpad output or explicit equal-tempered MIDI approximation in the Scale Editor. Drum MIDI is unaffected."
            return
        }
        cancelStartupGreeting()
        guard requireEngine(), let touch else { return }
        var configuration = configuration
        configuration.magicMouseOrientation = magicMouseOrientation
        currentTouchConfiguration = configuration
        touchMIDIOutEnabled = midiOut
        touchMIDIMode = midiMode
        touchMultiTouchEnabled = multiTouch
        touchMIDIChannel = max(0, min(15, midiChannel))
        touchSeparateChannels = separateChannels
        touchIndependentDAWSustain = separateChannels != nil && independentDAWSustain
        touchSustainSettings = sustainSettings
        touch.invalidatePendingSamples()
        liveTouchStates = []
        touchSustainRearmGate.reset()
        touchSustainState.reset()

        if !instrumentPreviewRequested {
            startTouchPreview(configuration: configuration)
        } else {
            updateTouchConfiguration(configuration)
        }
        guard touchPreviewRunning else { return }
        if let message = missingNativeSurfaceMessage(Set(configuration.selectedSurfaces)) {
            touchMIDIOutEnabled = false
            touchSeparateChannels = nil
            touchIndependentDAWSustain = false
            lastError = message
            return
        }

        if midiOut, !midiRunning {
            startMIDI()
            guard midiRunning else { return }
        }

        touchClickFence.begin(now:ProcessInfo.processInfo.systemUptime)
        touch.setActive(true)
        touchRunning = true
        startPerformanceEventMonitor()
        engineStatus = midiOut
            ? (configuration.fretless
               ? "Touch Instrument active · Fretless \(midiMode.rawValue) Out"
               : "Touch Instrument active · \(midiMode.rawValue) Out")
            : (configuration.fretless
               ? "Touch Instrument active · Fretless"
               : "Touch Instrument active")
    }

    func startTouch(rootMIDI: Int, scale: TouchScale, fretless: Bool = false, midiOut: Bool = false) {
        startTouch(
            configuration: .init(
                baseMIDINote: rootMIDI,
                scale: scale,
                fretless: fretless,
                masterLevel: masterLevel
            ),
            midiOut: midiOut
        )
    }

    func stopTouch() {
        touchClickFence.end()
        touchSustainRearmGate.reset()
        touchSeparateChannels = nil
        touchIndependentDAWSustain = false
        midi?.releaseTouchSustain()
        touchSustainState.reset()
        touchInstrumentSustainActive = false
        touch?.setActive(false)
        midi?.endAllTouchOutput()
        touchRunning = false
        touchMIDIOutEnabled = false
        liveTouchStates = []
        touchPreviewCadence.reset()
        if !instrumentPreviewRequested {
            touchStates = []
            touchContact = TrackpadContact()
        }
        refreshSharedSurfaceMonitoring()
        engineStatus = touchPreviewRunning
            ? "Touch preview active · no MIDI or haptic output until Start"
            : (engineReady ? "Force Touch trackpad ready" : engineStatus)
        stopCaptureMonitorIfIdle()
    }

    private func previewContactEdge(_ old: [TouchPerformanceState], _ next: [TouchPerformanceState]) -> Bool {
        if old.count != next.count { return true }
        return zip(old,next).contains { a,b in
            a.contactID != b.contactID || a.surface != b.surface ||
            a.isDown != b.isDown || a.isTouching != b.isTouching
        }
    }

    private func handleTouchStates(_ states: [TouchPerformanceState],pedal:MIDIHelperSustainSnapshot?,admitOnset:()->Bool) {
        liveTouchStates = states
        // Pedals were already evaluated and settled by the shared frame.
        if touchRunning {
            if touchMIDIOutEnabled {
                midi?.sendTouchStates(
                    states,
                    configuration: currentTouchConfiguration,
                    midiMode: touchMIDIMode,
                    baseChannel: touchMIDIChannel,
                    multiTouchEnabled: touchMultiTouchEnabled,
                    separateChannels: touchSeparateChannels,
                    sustainNewVoices: pedal?.isActive == true,
                    admitOnset:admitOnset
                )
            }
        }
        guard instrumentPreviewRequested, states != touchStates,
              touchPreviewCadence.permits(now:ProcessInfo.processInfo.systemUptime,cleared:states.isEmpty,
                  contactEdge:previewContactEdge(touchStates,states)) else { return }
        touchStates = states
        if let first = states.first(where: { $0.surface == .trackpad && $0.isTouching }) {
            touchContact = TrackpadContact(id:first.contactID,isDown:true,x:Float(first.x),y:Float(first.y),size:Float(first.pressure))
        } else if touchContact.isDown {
            touchContact = TrackpadContact()
        }
    }

    func startMIDI() {
        guard !midiRunning, allowLivePerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine(), let midi else { return }
        midiSessionEpoch.begin()
        guard let session = midiSessionEpoch.token else { return }
        do {
            let generation = engineGeneration
            try midi.start(masterLevel: masterLevel,onFailure:{ [weak self] status in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation,
                          self.midiSessionEpoch.accepts(session) else { return }
                    // Release using the intact service owner ledgers before
                    // producer stop methods can remove them.
                    self.midi?.stop()
                    // Stop only producers on the shared legacy source.
                    if self.touchRunning && self.touchMIDIOutEnabled { self.stopTouch() }
                    if self.midiHelperRunning { self.stopMIDIHelper() }
                    self.stopMIDI()
                    self.lastError = "MIDI output failed (OSStatus \(status)). Check the DAW; cleanup is not receiver-confirmed."
                }
            }) { [weak self] message in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation, self.midiRunning,
                          self.midiSessionEpoch.accepts(session) else { return }
                    self.lastMIDIMessage = "Ch \(message.channel + 1) · Note \(message.note) · Velocity \(message.velocity) · \(message.isNoteOn ? "On" : "Off")"
                    let key = "\(message.channel)-\(message.note)"
                    if message.isNoteOn {
                        self.activeMIDINoteMap[key] = .init(
                            channel: message.channel,
                            note: message.note,
                            velocity: message.velocity
                        )
                    } else {
                        self.activeMIDINoteMap.removeValue(forKey: key)
                    }
                    self.activeMIDINotes = self.activeMIDINoteMap.values.sorted {
                        if $0.channel == $1.channel { return $0.note < $1.note }
                        return $0.channel < $1.channel
                    }
                }
            }
            midiRunning = true
            engineStatus = "MIDI bridge active · Haptic MIDI In + Touch MIDI Out"
        } catch { midiSessionEpoch.end(); fail(error) }
    }

    func stopMIDI() {
        // Do not disconnect the virtual MIDI endpoint while an independently
        // enabled Touch Instrument or MIDI Helper still needs Logic.
        if (touchRunning && touchMIDIOutEnabled) || midiHelperRunning {
            engineStatus = "MIDI remains active for running instruments"
            return
        }
        // Retire the legacy Tilt producer before stopping its MIDI bridge.
        // Otherwise the next hardware poll can auto-start the stopped source.
        if !touchBarProfile.effectiveOutput.sendsHaptics { enableLiveHinge(false) }
        // The whole legacy source is stopping: settle actual attempted
        // MIDI output before individual UI owners can perform a handoff.
        midiSessionEpoch.end()
        midi?.stop()
        if !touchBarProfile.effectiveOutput.sendsHaptics {
            releaseTouchBarNotes()
            touchBarSustainOn = false
        }
        captureMonitor?.releasePointer()
        // A haptic-only Touch session has no owner in this MIDI bridge.
        // Keep its pedal latch and driver sustain synchronized when MIDI stops.
        if !touchRunning {
            touchSustainState.reset()
            touchSustainRearmGate.reset()
            touchInstrumentSustainActive = false
        }
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        midiHelperRunning = false
        midiRunning = false
        stopCaptureMonitorIfIdle()
        activeMIDINoteMap.removeAll()
        activeMIDINotes = []
        engineStatus = touchRunning ? "Touch Instrument active · MIDI bridge stopped" :
            (engineReady ? "Force Touch trackpad ready" : engineStatus)
        if midi?.hasUnconfirmedOutgoingCleanup == true {
            lastError = midi?.requiresManualDAWReset == true
                ? "Reset DAW controllers and quit/relaunch this app."
                : "MIDI cleanup remains unconfirmed. Retry Stop to release pending notes and controllers."
        }
    }

    func startMIDIHelperPreview(surfaceSelection: TouchSurfaceSelection) {
        guard requireEngine() else { return }
        // Preserve the live helper's previously chosen surface until the user
        // explicitly changes it; navigating away/back must not re-route MIDI.
        if midiHelperRunning {
            helperPreviewRequested = true
            refreshSharedSurfaceMonitoring()
            return
        }
        helperSurfaceSelection = surfaceSelection
        helperPreviewRequested = true
        refreshSharedSurfaceMonitoring()
        if !touchRunning && !midiHelperRunning {
            engineStatus = "MIDI Helper preview active"
        }
    }

    func updateMIDIHelperSurface(_ surfaceSelection: TouchSurfaceSelection) {
        if midiHelperRunning && surfaceSelection != helperSurfaceSelection,
           let message = missingNativeSurfaceMessage(Set(TouchSurfaceKind.allCases.filter { surfaceSelection.accepts($0) })) {
            stopMIDIHelper()
            helperSurfaceSelection = surfaceSelection
            lastError = message
            return
        }
        if midiHelperRunning && surfaceSelection != helperSurfaceSelection {
            let sequence = touch?.consumerPublicationBoundary().sequence ?? 0
            helperPedalPublicationFence.begin(after:sequence)
            helperEffectsPublicationFence.begin(after:sequence)
            helperClickFence.begin(now:ProcessInfo.processInfo.systemUptime)
            liveHelperStates = []
            helperSustainState.reset()
            helperRearmGate.invalidate()
            helperEffectsRearmGate.invalidate()
            midi?.releaseHelperSustain()
            if helperSendToDAW {
                midi?.resetHelperControls(assignments:helperAssignments,channel:helperTargetChannel,
                    vibratoCC:helperVibratoCC,expressionCC:helperExpressionCC)
            }
            midiHelperSustainActive = false
            midiHelperTrackpadSustainActive = false
            midiHelperMagicMouseSustainActive = false
        }
        helperSurfaceSelection = surfaceSelection
        refreshSharedSurfaceMonitoring()
    }

    func startMIDIHelper(
        assignments: MIDIHelperAssignments,
        surfaceSelection: TouchSurfaceSelection,
        sendToDAW: Bool,
        localSound: Bool,
        targetChannel: Int,
        pitchBendRange: Int,
        vibratoCC: Int = 1,
        expressionCC: Int = 11,
        trackpadSustainEnabled: Bool = false,
        trackpadSustainThreshold: Double = 0.55,
        magicMouseSustainEnabled: Bool = false,
        magicMouseSustainGesture: MagicMouseSustainGesture = .touchHold,
        trackpadSustainGesture: TrackpadSustainGesture = .contactThreshold,
        trackpadSustainSensor: TrackpadSustainSensor = .contactSize,
        magicMouseTapThreshold: Double = 0,
        sharePedalSurface:Bool = false,
        configureReceiverBendRange:Bool = false
    ) {
        guard allowLivePerformance() else { return }
        if midiHelperRunning,
           let message = missingNativeSurfaceMessage(Set(TouchSurfaceKind.allCases.filter { surfaceSelection.accepts($0) })) {
            stopMIDIHelper()
            lastError = message
            return
        }
        guard !sendToDAW || HelperCCPolicy.permits(vibrato:assignments.vibrato,expression:assignments.expression,
                                                   vibratoCC:vibratoCC,expressionCC:expressionCC) else {
            // Reject the new configuration and stop any old active helper
            // rather than display settings that do not match live routing.
            stopMIDIHelper()
            lastError = "Choose distinct expressive CCs. Bank, sustain, RPN/NRPN and channel-mode controls are reserved."
            return
        }
        cancelStartupGreeting()
        let newSustainSettings = MIDIHelperSustainSettings(
            trackpadEnabled: trackpadSustainEnabled,
            trackpadContactThreshold: trackpadSustainThreshold,
            magicMouseEnabled: magicMouseSustainEnabled,
            magicMouseGesture: magicMouseSustainGesture,
            trackpadGesture: trackpadSustainGesture,
            trackpadSensor: trackpadSustainSensor,
            magicMouseTapThreshold: magicMouseTapThreshold
        )
        let oldRouting = HelperRoutingSnapshot(sendToDAW:helperSendToDAW,channel:helperTargetChannel,
            bendRange:helperPitchBendRange,vibratoCC:helperVibratoCC,expressionCC:helperExpressionCC,configureReceiverBendRange:helperConfigureReceiverBendRange)
        let nextRouting = HelperRoutingSnapshot(sendToDAW:sendToDAW,channel:targetChannel,
            bendRange:pitchBendRange,vibratoCC:vibratoCC,expressionCC:expressionCC,configureReceiverBendRange:configureReceiverBendRange)
        let transition = HelperMappingTransition(old:oldRouting,next:nextRouting,
            oldAssignments:helperAssignments,nextAssignments:assignments,
            pedalSettingsChanged:newSustainSettings != helperSustainSettings,
            surfaceChanged:surfaceSelection != helperSurfaceSelection,
            sharingChanged:sharePedalSurface != helperSharePedalSurface)
        if !midiHelperRunning || transition.pedalChanged {
            helperClickFence.begin(now:ProcessInfo.processInfo.systemUptime)
        }
        let boundary = touch?.consumerPublicationBoundary()
        if !midiHelperRunning || transition.pedalChanged {
            helperPedalPublicationFence.begin(after:boundary?.sequence ?? 0)
        }
        if !midiHelperRunning || transition.effectsChanged {
            helperEffectsPublicationFence.begin(after:boundary?.sequence ?? 0)
        }
        // An effects-only edit must not clear an independent held pedal.
        if !midiHelperRunning || transition.pedalChanged { liveHelperStates = [] }
        if midiHelperRunning {
            if transition.effectsChanged {
                if helperSendToDAW {
                    midi?.resetHelperControls(assignments:helperAssignments,channel:helperTargetChannel,
                        vibratoCC:helperVibratoCC,expressionCC:helperExpressionCC)
                }
                helperEffectsRearmGate.invalidate()
            }
            if transition.pedalChanged {
                midi?.releaseHelperSustain()
                helperSustainState.reset()
                helperRearmGate.invalidate()
                midiHelperSustainActive = false
                midiHelperTrackpadSustainActive = false
                midiHelperMagicMouseSustainActive = false
            }
        } else {
            helperRearmGate.reset()
            helperEffectsRearmGate.reset()
            // Do not turn a pre-start held contact into a new pedal or
            // expressive onset. An explicitly idle start is immediately ready.
            if boundary?.touching.contains(where: { surfaceSelection.accepts($0) }) == true {
                helperRearmGate.invalidate()
                helperEffectsRearmGate.invalidate()
            }
        }
        helperSustainSettings = newSustainSettings
        helperAssignments = assignments
        helperSharePedalSurface = sharePedalSurface
        helperSurfaceSelection = surfaceSelection
        helperSendToDAW = sendToDAW
        helperLocalSound = localSound
        helperTargetChannel = max(0, min(15, targetChannel))
        helperPitchBendRange = max(1, min(24, pitchBendRange))
        helperConfigureReceiverBendRange = configureReceiverBendRange
        helperVibratoCC = max(0, min(127, vibratoCC))
        helperExpressionCC = max(0, min(127, expressionCC))

        if !helperPreviewRequested {
            startMIDIHelperPreview(surfaceSelection: surfaceSelection)
        } else {
            updateMIDIHelperSurface(surfaceSelection)
        }
        guard touchPreviewRunning else { return }
        if let message = missingNativeSurfaceMessage(Set(TouchSurfaceKind.allCases.filter { surfaceSelection.accepts($0) })) {
            lastError = message
            return
        }

        if !midiRunning {
            startMIDI()
            guard midiRunning else { return }
        }
        midi?.setInputHapticsEnabled(localSound)
        midiHelperRunning = true
        startPerformanceEventMonitor()
        engineStatus = assignments.hasEffects ? "MIDI Helper active · expressive CC mapping" : "MIDI Helper active · sustain-only CC64"
    }

    func stopMIDIHelper() {
        guard midiHelperRunning else { return }
        helperClickFence.end()
        let sequence = touch?.consumerPublicationBoundary().sequence ?? 0
        helperPedalPublicationFence.begin(after:sequence)
        helperEffectsPublicationFence.begin(after:sequence)
        liveHelperStates = []
        midi?.releaseHelperSustain()
        helperRearmGate.reset()
        helperEffectsRearmGate.reset()
        helperSustainState.reset()
        midiHelperSustainActive = false
        midiHelperTrackpadSustainActive = false
        midiHelperMagicMouseSustainActive = false
        if helperSendToDAW {
            midi?.resetHelperControls(
                assignments: helperAssignments,
                channel: helperTargetChannel,
                vibratoCC: helperVibratoCC,
                expressionCC: helperExpressionCC
            )
        }
        midi?.setInputHapticsEnabled(true)
        midiHelperRunning = false
        if !helperPreviewRequested { midiHelperStates = [] }
        refreshSharedSurfaceMonitoring()
        stopCaptureMonitorIfIdle()
        engineStatus = touchPreviewRunning ? "Surface monitoring active" : "MIDI bridge active"
    }

    func stopMIDIHelperPreview() {
        helperPreviewRequested = false
        helperPreviewCadence.reset()
        if !midiHelperStates.isEmpty { midiHelperStates = [] }
        guard !midiHelperRunning else { return }
        liveHelperStates = []
        midiHelperStates = []
        refreshSharedSurfaceMonitoring()
        stopCaptureMonitorIfIdle()
    }

    private func evaluateHelperSustain(_ states: [HelperSurfaceContact],freshFrame:Bool) -> Bool? {
        guard midiHelperRunning else { return nil }
        let selectedClick = helperClickFence.permits(receipt:physicalClickReceipt,
            now:ProcessInfo.processInfo.systemUptime,selected:clickedSurface.map { helperSurfaceSelection.accepts($0) } ?? false)
        let touching = states.contains { helperSurfaceSelection.accepts($0.surface) }
        guard helperRearmGate.permits(touching:touching,clicking:selectedClick,freshFrame:freshFrame) else { return nil }
        let active = states.filter { helperSurfaceSelection.accepts($0.surface) && HelperPerformancePolicy.validContact(x:$0.x,y:$0.y,size:$0.pressure) }
        let snapshot = helperSustainState.update(
            trackpadContactSizes: active
                .filter { $0.surface == .trackpad }
                .map(\.pressure),
            magicMouseTouching: active.contains { $0.surface == .magicMouse },
            settings: helperSustainSettings.restricted(trackpad:helperSurfaceSelection.accepts(.trackpad),
                magicMouse:helperSurfaceSelection.accepts(.magicMouse)),
            trackpadClickDown: selectedClick && clickedSurface == .trackpad,
            magicMouseClickDown: selectedClick && clickedSurface == .magicMouse,
            trackpadClickPressure: trackpadClickPressure,
            magicMouseContactSizes: active.filter { $0.surface == .magicMouse }.map(\.pressure),
            freshContacts:freshFrame
        )
        if midiHelperTrackpadSustainActive != snapshot.trackpadActive { midiHelperTrackpadSustainActive = snapshot.trackpadActive }
        if midiHelperMagicMouseSustainActive != snapshot.magicMouseActive { midiHelperMagicMouseSustainActive = snapshot.magicMouseActive }
        let helperSustained = snapshot.isActive && helperSendToDAW
        if midiHelperSustainActive != helperSustained { midiHelperSustainActive = helperSustained }

        return helperSustained
    }

    private func handleMIDIHelperStates(_ states: [HelperSurfaceContact],pedalAdmitted:Bool,effectsAdmitted:Bool,admitOnset:(()->Bool)? = nil) {
        if pedalAdmitted || !midiHelperRunning { liveHelperStates = states }
        defer {
            if helperPreviewRequested, states != midiHelperStates,
               helperPreviewCadence.permits(now:ProcessInfo.processInfo.systemUptime,cleared:states.isEmpty,
                   contactEdge:midiHelperStates.map(\.id) != states.map(\.id)) {
                midiHelperStates = states
            }
        }
        guard midiHelperRunning,effectsAdmitted else { return }
        let selectedClick = helperClickFence.permits(receipt:physicalClickReceipt,
            now:ProcessInfo.processInfo.systemUptime,selected:clickedSurface.map { helperSurfaceSelection.accepts($0) } ?? false)
        let touching = states.contains { helperSurfaceSelection.accepts($0.surface) }
        let effectsReady = helperEffectsRearmGate.permits(touching:touching,clicking:selectedClick,freshFrame:true)
        // This path receives accepted multitouch frames only.
        guard helperSendToDAW,effectsReady else { return }
        let active = states.filter { helperSurfaceSelection.accepts($0.surface) && HelperPerformancePolicy.validContact(x:$0.x,y:$0.y,size:$0.pressure) }
        // Sustain-only is a strict gate path. No pitch, CC7/11, pressure,
        // note or RPN generation from these contacts.
        guard helperAssignments.hasEffects else { return }

        let expressive = active.filter {
            HelperPerformancePolicy.permitsEffects(isTrackpad:$0.surface == .trackpad,settings:helperSustainSettings,sharePedalSurface:helperSharePedalSurface)
        }
        guard !expressive.isEmpty else {
            midi?.idleHelperControls()
            return
        }

        // Multi-touch helper aggregation:
        // horizontal = average bend, vertical = strongest vibrato, pressure = strongest expression.
        let x = expressive.map(\.x).reduce(0, +) / Double(expressive.count)
        let y = expressive.map(\.y).max() ?? 0
        let pressure = expressive.map(\.pressure).max() ?? 0

        midi?.sendHelperControls(
            x: x,
            y: y,
            contactSize: pressure,
            assignments: helperAssignments,
            channel: helperTargetChannel,
            pitchBendRange: helperPitchBendRange,
            vibratoCC: helperVibratoCC,
            expressionCC: helperExpressionCC,
            configureReceiverBendRange:helperConfigureReceiverBendRange,
            admitOnset:admitOnset
        )
    }

    /// Read-only report for the Diagnostics panel. Never records key contents,
    /// typed text, device identifiers, user paths, or private recordings.
    func resetTouchDispatchMetrics() {
        touchDispatchMetrics = TouchDispatchMetrics()
        touch?.resetHapticDiagnostics()
    }

    func touchDispatchDiagnosticReport() -> String {
        let m = touchDispatchMetrics
        let hapticReport: String
        if let h = touch?.hapticDiagnosticSnapshot() {
            hapticReport = """
            Trackpad max contacts / triggered: \(h.trackpadRawMax) / \(h.trackpadTriggeredMax)
            Magic Mouse max contacts / triggered: \(h.mouseRawMax) / \(h.mouseTriggeredMax)
            Drum strikes accepted / drained: \(h.acceptedDrumStrikes) / \(h.drainedDrumStrikes)
            Motor calls returned / threw: \(h.motorSubmissions) / \(h.motorErrors)
            Touch motor fault latched: \(h.outputFaulted ? "YES" : "NO")
            Contact counts are committed active frames. Motor calls do not prove physical vibration.
            """
        } else { hapticReport = "Touch diagnostics unavailable." }
        func ms(_ seconds: Double) -> String { String(format:"%.2f ms",seconds*1000) }
        return """
        Accepted snapshots: \(m.count)
        Rejected stale/reordered snapshots: \(m.rejected)
        Main queue mean / max: \(ms(m.queueMean)) / \(ms(m.queueMax))
        Queue delays ≥ 10 ms: \(m.queueOver10ms)
        Main processing mean / max: \(ms(m.processingMean)) / \(ms(m.processingMax))
        Callback-to-main timing only; not hardware-to-audio latency.

        \(hapticReport)
        """
    }

    func globalCaptureDiagnosticReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let build = Bundle.main.infoDictionary?["NoSpeakerBuildSHA"] as? String ?? "unknown"
        let snapshot = (captureMonitor ?? PerformanceCaptureMonitor()).diagnosticSnapshot()

        func yesNo(_ yes: Bool) -> String { yes ? "YES" : "NO" }

        let suggestion: String
        if !snapshot.accessibilityGranted {
            suggestion = "Accessibility permission not granted. Enable this installed app in Privacy & Security > Accessibility, then quit and reopen."
        } else if !snapshot.inputMonitoringGranted && !snapshot.eventTapEnabled {
            suggestion = "Input Monitoring preflight is not granted and the event tap is inactive. Inspect Privacy & Security > Input Monitoring, quit and reopen."
        } else if captureArmed && !snapshot.eventTapCreated {
            suggestion = "Capture is armed, but no event tap exists. Disable and re-enable Global Capture; inspect the status and macOS permissions."
        } else if captureArmed && !snapshot.eventTapEnabled {
            suggestion = "Capture is armed, but macOS reports the event tap disabled. Re-enable Global Capture; check the timeout/disable counters."
        } else if !captureArmed {
            suggestion = "Global Capture is OFF. Arm it, refresh this report, switch to another app, press the recorded shortcut twice, then refresh again."
        } else if snapshot.shortcutMatches == 0 {
            suggestion = "Tap is enabled but no shortcut match has been observed since monitor creation. Press the recorded combination in another app and compare Key downs / Shortcut matches."
        } else {
            suggestion = "Shortcut matches are observed. If the cursor still moves when captured, compare pointer counts and Pointer captured while using another app."
        }

        return """
        TIHULU Global Capture Diagnostics (read-only)
        App version: \(version)
        Build: \(build)
        macOS: \(os)
        Haptic engine ready: \(yesNo(engineReady))
        Global Capture toggle: \(yesNo(captureArmed))
        Recorded shortcut: \(captureShortcut.displayName)
        Accessibility trusted: \(yesNo(snapshot.accessibilityGranted))
        Input Monitoring preflight: \(yesNo(snapshot.inputMonitoringGranted))
        Event tap created: \(yesNo(snapshot.eventTapCreated))
        Event tap enabled by macOS: \(yesNo(snapshot.eventTapEnabled))
        Dedicated capture thread: \(yesNo(snapshot.dedicatedInputThread))
        Monitor listening flag: \(yesNo(snapshot.listening))
        Shortcut armed inside monitor: \(yesNo(snapshot.shortcutArmed))
        Pointer captured: \(yesNo(snapshot.pointerCaptured))
        Key-down events observed: \(snapshot.keyDownEvents)
        Pointer events observed: \(snapshot.pointerEvents)
        Matched shortcuts: \(snapshot.shortcutMatches)
        Event tap timeouts: \(snapshot.tapTimeouts)
        Event tap disabled by system/user: \(snapshot.tapDisabledByUserInput)
        Coalesced pressure samples: \(snapshot.coalescedPressureSamples)
        Physical input mailbox overflows: \(snapshot.physicalMailboxOverflows)
        Previous monitor timeouts: \(lastRetiredCaptureSnapshot?.tapTimeouts ?? 0)
        Previous monitor mailbox overflows: \(lastRetiredCaptureSnapshot?.physicalMailboxOverflows ?? 0)
        Last event tap status: \(snapshot.lastEventTapStatus)
        Previous monitor status: \(lastRetiredCaptureStatus ?? "None")
        Current capture status: \(captureStatus)
        Touch instrument running: \(yesNo(touchRunning))
        Touch preview running: \(yesNo(touchPreviewRunning))
        MIDI helper running: \(yesNo(midiHelperRunning))
        Suggested next check: \(suggestion)

        Note: Counts refer to the current input monitor lifetime. The Input Monitoring
        preflight is an OS permission hint, not proof that a filtering event tap
        is operational. Raw keystrokes and typed text are NEVER saved here.
        """
    }

    func configurePerformanceCapture(
        armed: Bool,
        shortcut: PerformanceCaptureShortcut
    ) {
        guard !armed || !groupGamepadsRunning else { lastError = "Stop group MIDI before arming Capture."; return }
        guard shortcut.isValid else {
            lastError = PerformanceCaptureError.invalidShortcut.localizedDescription
            return
        }
        captureShortcut = shortcut
        captureArmed = armed
        captureHotkeyArmed = armed
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "TIHULU.captureShortcut")
        }
        captureMonitor?.setShortcut(shortcut)
        captureMonitor?.setCaptureHotkeyEnabled(armed)
        if armed || touchRunning || midiHelperRunning {
            startPerformanceEventMonitor()
        } else {
            stopCaptureMonitorIfIdle()
        }
        if !armed {
            captureMonitor?.releasePointer()
            pointerCaptured = false
        }
    }

    /// Capture is a separate opt-in input service, not a haptic driver resource.
    /// Each retired monitor has its own callback fence.
    private func ensureCaptureMonitor() -> PerformanceCaptureMonitor {
        if let captureMonitor { return captureMonitor }
        // Preview may have continued while the previous tap was absent.
        // A newly created tap must not inherit those contact observations.
        clearClickAttribution()
        captureGeneration &+= 1
        let generation = captureGeneration
        let panicEngineGeneration = engineGeneration
        let capture = PerformanceCaptureMonitor()
        capture.onCaptureChanged = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                guard let monitor=self.captureMonitor else { return }
                let health=monitor.diagnosticSnapshot()
                self.pointerCaptured = health.pointerCaptured
                // A queued change from an already disabled tap must not
                // overwrite the error/recovery status with false readiness.
                guard health.operational else { return }
                if self.captureArmed || self.touchRunning || self.midiHelperRunning {
                    self.captureStatus = self.pointerCaptured
                        ? "Cursor captured · press the shortcut again or Esc"
                        : (health.readyForGlobalCapture
                            ? "Cursor free · global shortcut ready"
                            : "Cursor free · physical-click monitor active")
                }
            }
        }
        capture.onPanic = { [weak self] in
            Task { @MainActor in
                guard let self,PerformanceCaptureSafety.acceptsEmergencyRequest(
                    engineAtCapture:panicEngineGeneration,currentEngine:self.engineGeneration) else { return }
                // Tap replacement/disarm cannot cancel an already accepted
                // Escape. Explicit engine retirement fences old requests.
                self.panicStop()
            }
        }
        capture.onPhysicalInputAvailable = { [weak self] in
            Task { @MainActor in
                guard let self,self.captureGeneration == generation,
                      let monitor = self.captureMonitor else { return }
                let batch = monitor.drainPhysicalInput()
                if batch.invalidated || batch.events.count != batch.receipts.count {
                    self.invalidatePhysicalClickState()
                    return
                }
                for (event,receipt) in zip(batch.events,batch.receipts) {
                    guard self.captureGeneration == generation else { return }
                    guard monitor.acceptsPhysicalInput(batch) else {
                        self.invalidatePhysicalClickState()
                        return
                    }
                    switch event {
                    case .click(let down,let pressure): self.handlePhysicalClick(down,pressure:pressure,receipt:receipt)
                    case .pressure(let pressure): self.handlePhysicalPressure(pressure)
                    }
                }
            }
        }
        capture.onMonitorRecovered = { [weak self] in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                guard let monitor=self.captureMonitor else { return }
                let health=monitor.diagnosticSnapshot()
                guard health.operational else { return }
                self.pointerCaptured = health.pointerCaptured
                // This callback may arrive after a fresh capture shortcut.
                // Show the current state, not the historical timeout state.
                self.captureStatus = health.pointerCaptured
                    ? "Cursor captured · press the shortcut again or Esc"
                    : (health.readyForGlobalCapture
                        ? "Input monitor recovered · cursor free · press the capture shortcut to resume"
                        : "Input monitor recovered · cursor free · physical-click monitor active")
            }
        }
        capture.onMonitorFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                // macOS can disable a global event tap while the haptic driver
                // is still healthy. Never escalate that to a device panic.
                self.retireCaptureMonitor()
                self.invalidatePhysicalClickState()
                self.captureArmed = false
                self.captureHotkeyArmed = false
                self.clickedSurface = nil
                self.trackpadClickPressure = nil
                self.pointerCaptured = false
                self.captureStatus = "macOS disabled input monitoring · cursor free · enable Global Capture again to retry"
                // Preserve Voice/Touch/MIDI/Audio playback and the live driver.
            }
        }
        self.captureMonitor = capture
        return capture
    }

    private func retireCaptureMonitor() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        captureGeneration &+= 1
        let old = captureMonitor
        if let old {
            let snapshot = old.diagnosticSnapshot()
            lastRetiredCaptureSnapshot = snapshot
            lastRetiredCaptureStatus = snapshot.lastEventTapStatus
        }
        captureMonitor = nil
        old?.setCaptureHotkeyEnabled(false)
        old?.stop()
        pointerCaptured = false
    }

    private func startPerformanceEventMonitor() {
        // A user-armed shortcut remains available in Voice, MIDI,
        // Sequencers, Audio File, Speaker and Diagnostics, even before
        // a Touch/Helper performance starts. OFF remains the default.
        guard captureHotkeyArmed || touchRunning || midiHelperRunning else { return }
        var monitor = ensureCaptureMonitor()
        let before = monitor.diagnosticSnapshot()
        if before.eventTapCreated && (!before.listening || !before.eventTapEnabled) {
            retireCaptureMonitor()
            invalidatePhysicalClickState()
            monitor = ensureCaptureMonitor()
        }
        do {
            try monitor.start(shortcut: captureShortcut, requestPermissions: captureHotkeyArmed)
            monitor.setCaptureHotkeyEnabled(captureHotkeyArmed)
            let health=monitor.diagnosticSnapshot()
            guard health.operational, !captureHotkeyArmed || health.readyForGlobalCapture else {
                throw PerformanceCaptureError.tapUnavailable
            }
            pointerCaptured=health.pointerCaptured
            startCaptureHealthCheck()
            captureStatus = pointerCaptured
                ? "Cursor captured · press the shortcut again or Esc"
                : (captureHotkeyArmed
                    ? "Ready globally · \(captureShortcut.displayName) toggles capture · Esc stops all"
                    : "Cursor free · physical-click monitor active")
        } catch {
            retireCaptureMonitor()
            invalidatePhysicalClickState()
            captureStatus = "Global capture unavailable · check Accessibility and Input Monitoring permissions"
            if captureHotkeyArmed {
                lastError = error.localizedDescription
                captureArmed = false
                captureHotkeyArmed = false
            }
            pointerCaptured = false
        }
    }

    private func startCaptureHealthCheck() {
        guard captureHealthTask == nil else { return }
        let generation = captureGeneration
        captureHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
                guard let self,self.captureGeneration == generation,
                      let monitor = self.captureMonitor else { return }
                let health = monitor.diagnosticSnapshot()
                guard health.operational, !self.captureHotkeyArmed || health.readyForGlobalCapture else {
                    self.retireCaptureMonitor()
                    self.invalidatePhysicalClickState()
                    self.captureArmed = false
                    self.captureHotkeyArmed = false
                    self.captureStatus = "Input tap unavailable · cursor free · re-enable explicitly"
                    return
                }
            }
        }
    }

    func togglePointerCaptureNow() {
        guard let monitor=captureMonitor else {
            pointerCaptured=false
            captureStatus="Capture unavailable · enable Global Capture and check permissions"
            return
        }
        if !captureArmed {
            monitor.releasePointer()
            pointerCaptured=false
            captureStatus="Cursor free · Global Capture OFF"
            return
        }
        // Never toggle based on a stale SwiftUI flag. Native lock serializes
        // the explicit button with the global shortcut and timeout handler.
        _=monitor.togglePointerCapture()
        let health=monitor.diagnosticSnapshot()
        pointerCaptured=health.pointerCaptured
        captureStatus = pointerCaptured
            ? "Cursor captured · shortcut or Esc releases"
            : (health.readyForGlobalCapture
                ? "Cursor free"
                : "Capture unavailable · enable Global Capture and check permissions")
    }

    private func stopCaptureMonitorIfIdle() {
        if !captureHotkeyArmed && !touchRunning && !midiHelperRunning {
            retireCaptureMonitor()
            // Preview can outlive the capture monitor. Never carry a
            // pressed edge or its attribution into the next monitor epoch.
            clearClickAttribution()
            pointerCaptured = false
            captureStatus = "Cursor free · global capture OFF"
        }
    }

    private func clearClickAttribution() {
        clickTouchingSurfaces.removeAll()
        clickSnapshotRevision = nil
        clickSnapshotReceivedAt = nil
        physicalClickReceipt = nil
        physicalClickDown = false
        clickedSurface = nil
        trackpadClickPressure = nil
        // Every explicit attribution reset is a publication boundary,
        // including preview-only, engine restart and monitor recreation.
        clickAttributionNotBefore=ProcessInfo.processInfo.systemUptime
    }

    private func invalidatePhysicalClickState() {
        helperSustainState.invalidatePhysicalClicks(settings:helperSustainSettings)
        touchSustainState.invalidatePhysicalClicks(settings:touchSustainSettings)
        handlePhysicalClick(false,pressure:0)
        clearClickAttribution()
    }

    private func handlePhysicalClick(_ down: Bool, pressure: Double,receipt:Double? = nil) {
        if down {
            guard !physicalClickDown else { return }
            physicalClickDown = true
            physicalClickReceipt = receipt
            // Use only the most recent shared, unfiltered monitor snapshot.
            clickedSurface = PhysicalClickAttribution.resolve(clickTouchingSurfaces,
                snapshotRevision:clickSnapshotRevision,currentRevision:touch?.currentSampleRevision,
                receivedAt:clickSnapshotReceivedAt,now:ProcessInfo.processInfo.systemUptime,clickReceipt:receipt,
                notBefore:clickAttributionNotBefore)
            trackpadClickPressure = clickedSurface == .trackpad && pressure.isFinite && (0...1).contains(pressure) ? pressure : nil
        } else {
            physicalClickDown = false
            physicalClickReceipt = nil
            clickedSurface = nil
            trackpadClickPressure = nil
        }
        applyPhysicalPedalFrame(touchStates:touchRunning ? liveTouchStates : nil,
            helperStates:midiHelperRunning ? liveHelperStates : nil,freshFrame:false)
    }

    private func handlePhysicalPressure(_ pressure: Double) {
        guard clickedSurface == .trackpad else { return }
        trackpadClickPressure = pressure.isFinite && (0...1).contains(pressure) ? pressure : nil
        applyPhysicalPedalFrame(touchStates:touchRunning ? liveTouchStates : nil,
            helperStates:midiHelperRunning ? liveHelperStates : nil,freshFrame:false)
    }

    @discardableResult
    private func applyPhysicalPedalFrame(touchStates:[TouchPerformanceState]?,
                                         helperStates:[HelperSurfaceContact]?,
                                         freshFrame:Bool,admitOnset:(()->Bool)? = nil) -> MIDIHelperSustainSnapshot? {
        let touchPedal = touchRunning ? touchStates.flatMap { evaluateTouchSustain($0,freshFrame:freshFrame) } : nil
        let helperPedal = midiHelperRunning ? helperStates.flatMap { evaluateHelperSustain($0,freshFrame:freshFrame) } : nil
        let midiTouch = touchMIDIOutEnabled ? touchPedal : nil
        if midiTouch != nil || helperPedal != nil {
            let routes = currentTouchConfiguration.selectedSurfaces.filter {
                currentTouchConfiguration.output(for:$0).sendsMIDI
            }.map { currentTouchConfiguration.instrument(for:$0) }
            let fixed = LegacyTouchSustainTargets.fixedChannels(baseChannel:touchMIDIChannel,
                hasMelody:routes.contains { $0 != .drums },hasDrums:routes.contains(.drums),
                isMPE:touchMIDIMode == .mpe)
            midi?.setPhysicalSustainFrame(touch:midiTouch,separateChannels:touchSeparateChannels,
                independent:touchIndependentDAWSustain,fixedTouchChannels:fixed,
                helper:helperPedal,helperChannel:helperTargetChannel,admitOnset:admitOnset)
        }
        return touchPedal
    }

    private func evaluateTouchSustain(_ states: [TouchPerformanceState],freshFrame:Bool) -> MIDIHelperSustainSnapshot? {
        let selected = states.filter { currentTouchConfiguration.surfaceSelection.accepts($0.surface) }
        let active = selected.filter { $0.isTouching && HelperPerformancePolicy.validContact(x:$0.x,y:$0.y,size:$0.pressure) }
        let selectedClick = touchClickFence.permits(receipt:physicalClickReceipt,
            now:ProcessInfo.processInfo.systemUptime,selected:clickedSurface.map { currentTouchConfiguration.surfaceSelection.accepts($0) } ?? false)
        guard touchSustainRearmGate.permits(touching:selected.contains(where: { $0.isTouching }),
            clicking:selectedClick,freshFrame:freshFrame) else { return nil }
        let snapshot = touchSustainState.update(
            trackpadContactSizes: active
                .filter { $0.surface == .trackpad }
                .map(\.pressure),
            magicMouseTouching: active.contains { $0.surface == .magicMouse },
            settings: touchSustainSettings.restricted(trackpad:currentTouchConfiguration.surfaceSelection.accepts(.trackpad),
                magicMouse:currentTouchConfiguration.surfaceSelection.accepts(.magicMouse)),
            trackpadClickDown: selectedClick && clickedSurface == .trackpad,
            magicMouseClickDown: selectedClick && clickedSurface == .magicMouse,
            trackpadClickPressure: trackpadClickPressure,
            magicMouseContactSizes: active.filter { $0.surface == .magicMouse }.map(\.pressure),
            freshContacts:freshFrame
        )
        let hapticsEnabled = currentTouchConfiguration.localHapticSound &&
            currentTouchConfiguration.selectedSurfaces.contains {
                currentTouchConfiguration.output(for: $0).sendsHaptics
            }
        let instrumentSustained = snapshot.isActive && (touchMIDIOutEnabled || hapticsEnabled)
        if touchInstrumentSustainActive != instrumentSustained { touchInstrumentSustainActive = instrumentSustained }
        touch?.setSustainActive(snapshot.isActive && hapticsEnabled)
        return snapshot
    }

    func playMIDIFile(_ url: URL) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        let token = beginPlaybackRequest()
        do {
            let data = try Data(contentsOf: url)
            let midi = try MIDIFileParser.parse(data)
            currentFileName = url.lastPathComponent
            playRendered(MIDIFileParser.hapticEvents(from: midi), token: token,
                         duration: midi.durationSeconds)
        } catch { fail(error) }
    }

    func playAudioFile(_ url: URL, profile: AudioHapticProfile? = nil) {
        guard allowRenderedPerformance() else { return }
        cancelStartupGreeting()
        guard requireEngine() else { return }
        currentFileName = url.lastPathComponent
        let selectedProfile = profile ?? activeProfile
        let fileURL = url
        let token = beginPlaybackRequest()
        let cancellation = VoiceRenderCancellation()
        voiceRenderCancellation = cancellation
        Task {
            defer {
                if voiceRenderCancellation === cancellation { voiceRenderCancellation = nil }
            }
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try AudioFileHapticService.render(url:fileURL,profile:selectedProfile,cancellation:cancellation)
                }.value
                try cancellation.check()
                guard renderGeneration == token, !liveNoteOwnsHaptics else { return }
                playRendered(events, token: token)
            } catch {
                guard renderGeneration == token else { return }
                fail(error)
            }
        }
    }

    func handleDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "mid" || ext == "midi" { playMIDIFile(url) }
        else { playAudioFile(url) }
    }

    func startSystemAudio() {
        guard !groupGamepadsRunning else { lastError = "Stop group MIDI first."; return }
        cancelStartupGreeting()
        guard !speakerBusy else { return }
        guard !liveNoteOwnsHaptics, !sequenceOwnsHaptics else {
            lastError = "Disarm the optional Trackpad note output before starting Speaker."
            return
        }
        guard !touchRunning, !midiHelperRunning, !midiRunning, !isPlaying, !liveHingeEnabled else {
            lastError = "Stop other performances and the MIDI bridge before starting Trackpad Speaker. The haptic motor is shared."
            return
        }
        guard requireEngine(), let systemAudio else { return }
        playback?.stop(closeDriver: false)
        speakerGeneration &+= 1
        let token = speakerGeneration
        systemAudioStarting = true
        engineStatus = "Starting system audio capture"
        speakerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await systemAudio.start(profile: speakerProfile, masterLevel: masterLevel,
                    speechOptimized: speakerOptimized, automaticGain: speakerAutomaticGain,
                    noiseGate: speakerNoiseGate, bufferSeconds: speakerBufferMS / 1000,
                    onFailure: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.speakerGeneration == token else { return }
                            self.stopSystemAudio()
                            self.lastError = "System audio stopped: " + message
                        }
                    })
                guard !Task.isCancelled, speakerGeneration == token else { return }
                systemAudioStarting = false
                systemAudioRunning = true
                engineStatus = "System audio active · buffered playback"
            } catch {
                guard speakerGeneration == token else { return }
                systemAudioStarting = false
                systemAudioRunning = false
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    func stopSystemAudio() {
        guard speakerBusy, !systemAudioStopping else { return }
        speakerGeneration &+= 1
        let token = speakerGeneration
        let oldTask = speakerTask
        let capture = systemAudio
        oldTask?.cancel()
        capture?.stopOutput()
        systemAudioRunning = false
        systemAudioStarting = false
        systemAudioStopping = true
        speakerTask = Task { [weak self] in
            await oldTask?.value
            await capture?.stop()
            guard let self, self.speakerGeneration == token else { return }
            self.systemAudioStopping = false
            self.speakerTask = nil
            if self.engineReady { self.engineStatus = "Force Touch trackpad ready" }
        }
    }

    private var renderedOutputPolicy: RenderedOutputPolicy {
        .init(rendered:isPlaying,touch:touchRunning,bridge:midiRunning,
              helper:midiHelperRunning,hinge:liveHingeEnabled)
    }

    private func allowRenderedPerformance() -> Bool {
        guard allowOtherPerformance() else { return false }
        guard renderedOutputPolicy.permitsRenderedStart else {
            lastError = "Stop live Touch, MIDI Bridge, Helper or Tilt before rendered playback. The haptic motor is shared."
            return false
        }
        return true
    }

    private func allowLivePerformance() -> Bool {
        guard allowOtherPerformance() else { return false }
        guard renderedOutputPolicy.permitsLiveStart else {
            lastError = "Stop rendered playback before starting live performance."
            return false
        }
        return true
    }

    private func allowOtherPerformance() -> Bool {
        guard !groupGamepadsRunning else {
            lastError = "Stop group MIDI before starting another live performance."
            return false
        }
        guard !sequenceOwnsHaptics else {
            lastError = "Stop the sequencer's combined Trackpad/MIDI output first."
            return false
        }
        guard !liveNoteOwnsHaptics else {
            lastError = "Disarm the optional Trackpad note output before starting another haptic performance."
            return false
        }
        guard !speakerBusy else {
            lastError = "Stop Trackpad Speaker before using another haptic or MIDI performance."
            return false
        }
        return true
    }

    private func requireEngine() -> Bool {
        if engineReady { return true }
        guard !speakerBusy else {
            lastError = "Wait for system audio capture to finish stopping."
            return false
        }
        prepareEngine()
        return engineReady
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        engineStatus = "Error"
        isPlaying = false
    }
}
#endif
