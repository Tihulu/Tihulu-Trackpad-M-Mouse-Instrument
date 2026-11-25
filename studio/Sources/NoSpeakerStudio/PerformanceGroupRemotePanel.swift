#if os(macOS)
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import NoSpeakerCore
import NoSpeakerMac

/// Explicit, separate mobile group setup. Never opens a listener on appearance.
/// The parent owns saved-profile admission and controller selection.
struct PerformanceGroupRemotePanel: View {
    @EnvironmentObject private var studio:StudioController
    let sources:[SensorSource]
    let canStart:Bool
    let tuning:PerformanceGroupTuningConfiguration?
    let canStartTuned:Bool
    let tunedConsent:DynamicMPEStartConsent?
    let start:(RemoteLoopbackTransport,RemoteLoopbackPageServer,Bool,PerformanceGroupTuningConfiguration?,DynamicMPEStartConsent?)->Void
    private struct StartSnapshot {
        let identityID:UUID
        let endpoint:RemoteEndpoint
        let lanID:String?
        let confirmedLAN:Bool
        let tuning:PerformanceGroupTuningConfiguration
        let consent:DynamicMPEStartConsent
    }
    @State private var pendingStart:StartSnapshot?
    @State private var confirmStart = false
    @State private var identities:[RemoteTLSIdentityChoice] = []
    @State private var identityID:UUID?
    @State private var lan = false
    @State private var choices:[RemoteLANChoice] = []
    @State private var selectedLAN:String?
    @State private var confirmedLAN = false
    @State private var source:SensorSource = .phone
    @State private var invitation = ""
    @State private var shareLabels = false
    @State private var invitationSource:SensorSource?
    @State private var invitationTask:Task<Void,Never>?
    @State private var invitationGeneration:UUID?
    @State private var message = ""

    private var endpoint:RemoteEndpoint? {
        lan ? choices.first(where:{ $0.id == selectedLAN })?.endpoint : .loopback
    }

    private func clearInvitation() {
        invitationGeneration = nil
        invitationTask?.cancel()
        invitationTask = nil
        invitation = ""
        invitationSource = nil
        studio.cancelGroupRemoteInvitation()
    }

    private func issue() {
        clearInvitation()
        guard studio.groupRemoteReady,sources.contains(source),!studio.groupRemoteSlots.values.contains(source) else { return }
        do {
            invitation = try studio.issueGroupRemoteInvitation(source:source,shareLabels:shareLabels)
                .map { String(format:"%02x",$0) }.joined()
            invitationSource = source
            let generation = UUID()
            invitationGeneration = generation
            invitationTask = Task {
                do { try await Task.sleep(for:.seconds(60)) } catch { return }
                guard invitationGeneration == generation else { return }
                clearInvitation()
            }
            message = shareLabels ? "One-time invitation created with label consent." : "One-time invitation created; labels hidden."
        } catch { message = "Invitation refused: slot is unavailable or already bound." }
    }

    private func requestTunedStart() {
        guard canStartTuned,let tuning,let tunedConsent,let identityID,let endpoint else { return }
        pendingStart = .init(identityID:identityID,endpoint:endpoint,lanID:selectedLAN,
                             confirmedLAN:confirmedLAN,tuning:tuning,consent:tunedConsent)
        confirmStart = true
    }

    private func begin(tuned snapshot:StartSnapshot? = nil) {
        if let snapshot {
            guard canStartTuned,tuning == snapshot.tuning,tunedConsent == snapshot.consent,identityID == snapshot.identityID,
                  endpoint == snapshot.endpoint,selectedLAN == snapshot.lanID,
                  confirmedLAN == snapshot.confirmedLAN else {
                message = "MPE setup changed; review and confirm again."
                return
            }
        }
        guard canStart,!studio.groupGamepadsRunning,
              let identity = identities.first(where:{ $0.id == identityID }),
              let endpoint else { return }
        if lan {
            guard confirmedLAN,studio.remoteLoopbackVerified,
                  RemoteLANChoice.available().contains(where:{ $0.id == selectedLAN && $0.endpoint == endpoint }) else {
                message = "Select and confirm a current trusted private address."
                return
            }
        }
        do {
            let transport = try identity.makeLoopbackTransport(endpoint:endpoint)
            let page = try identity.makeLoopbackPageServer(endpoint:endpoint,groupNeutralHandshake:true)
            start(transport,page,confirmedLAN,snapshot?.tuning,snapshot?.consent)
        } catch { message = "TLS setup failed. No trust bypass. " + error.localizedDescription }
    }

    private func pageQR(_ address:String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by:CGAffineTransform(scaleX:8,y:8))
        guard let cg = CIContext().createCGImage(scaled,from:scaled.extent) else { return nil }
        return NSImage(cgImage:cg,size:NSSize(width:scaled.extent.width,height:scaled.extent.height))
    }

    var body: some View {
        GroupBox("Mobile group controllers — experimental TLS") {
            VStack(alignment:.leading,spacing:7) {
                Text("Up to two mapped surface families per phone/tablet slot. Enable experimental combinations explicitly in the browser to play both together. MIDI addresses stay hidden. Custom labels are optional per invitation. Trusted TLS identity required.")
                    .font(.caption).foregroundStyle(.secondary)
                if !studio.groupGamepadsRunning {
                    Toggle("Private LAN (requires successful Builder loopback diagnostic)",isOn:$lan)
                        .disabled(!studio.remoteLoopbackVerified)
                        .onChange(of:lan) { _ in confirmedLAN = false }
                    if lan {
                        Button("Refresh private addresses") {
                            choices = RemoteLANChoice.available()
                            selectedLAN = nil
                            confirmedLAN = false
                        }
                        Picker("Bind address",selection:$selectedLAN) {
                            Text("Select address").tag(String?.none)
                            ForEach(choices) { choice in
                                Text(choice.interface + " · " + choice.endpoint.host).tag(Optional(choice.id))
                            }
                        }.onChange(of:selectedLAN) { _ in confirmedLAN = false }
                        Toggle("I trust this private network and the matching TLS identity",isOn:$confirmedLAN)
                    }
                    Button("Load Keychain TLS identities") {
                        do {
                            identities = try RemoteTLSIdentityChoice.available()
                            identityID = nil
                        } catch { message = error.localizedDescription }
                    }
                    Picker("TLS identity",selection:$identityID) {
                        Text("Select identity").tag(UUID?.none)
                        ForEach(identities) { choice in Text(choice.name).tag(Optional(choice.id)) }
                    }
                    Button(lan ? "Start standard MIDI + LAN" : "Start standard MIDI + loopback") { begin() }
                        .disabled(!canStart || identityID == nil || endpoint == nil ||
                                  (lan && (!confirmedLAN || !studio.remoteLoopbackVerified)))
                    if StudioController.groupMPEStartEnabled {
                        Button(lan ? "Start group MPE + LAN" : "Start group MPE + loopback") { requestTunedStart() }
                            .disabled(!canStartTuned || identityID == nil || endpoint == nil ||
                                      (lan && (!confirmedLAN || !studio.remoteLoopbackVerified)))
                        Text("MPE requires a matching applied tuning configuration and all retained ports closed.")
                            .font(.caption)
                    }
                    Text("Do not forward ports or ignore certificate warnings. LAN remains locked until the existing local Builder diagnostic passes.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(studio.groupRemoteStatus).font(.caption)
                    if studio.groupRemoteReady,let endpoint = studio.groupRemoteEndpoint {
                        Text(endpoint.pageURL).font(.caption).textSelection(.enabled)
                        Button("Open controller page") {
                            if let url = URL(string:endpoint.pageURL) { NSWorkspace.shared.open(url) }
                        }
                        if !endpoint.isLoopback,let qr = pageQR(endpoint.pageURL) {
                            Image(nsImage:qr).interpolation(.none).resizable()
                                .frame(width:144,height:144)
                                .accessibilityLabel("Controller page address QR code")
                            Text("Scan the address, then enter the separate one-time secret. QR contains no invitation.")
                                .font(.caption)
                        }
                        Picker("Remote slot",selection:$source) {
                            ForEach(sources,id:\.self) { slot in
                                Text(slot.rawValue + (studio.groupRemoteSlots.values.contains(slot) ? " · connected" : " · available")).tag(slot)
                            }
                        }.onChange(of:source) { _ in clearInvitation(); shareLabels = false }
                        Toggle("Share this slot's custom control labels",isOn:$shareLabels)
                            .onChange(of:shareLabels) { _ in clearInvitation() }
                        Text("Labels may contain personal text. Off by default; changing consent requires a new invitation. Existing peers must disconnect and pair again.")
                            .font(.caption)
                        if shareLabels {
                            let labels = studio.groupRemoteLabelPreview(source:source)
                            DisclosureGroup("Review " + String(labels.count) + " labels before sharing") {
                                if labels.isEmpty {
                                    Text("No valid unambiguous custom labels are available.").font(.caption)
                                } else {
                                    ForEach(Array(labels.enumerated()),id:\.offset) { item in
                                        Text(item.element).font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        Button("Create one-time invitation") { issue() }
                            .disabled(!sources.contains(source) || studio.groupRemoteSlots.values.contains(source))
                        if !invitation.isEmpty {
                            Text(invitation).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            Text("Enter the secret on the controller within 60 seconds. Treat it as a password. The browser arms all mapped surfaces before playing.")
                                .font(.caption)
                            Button("Cancel invitation") { clearInvitation() }
                        }
                    }
                    Text("\(studio.groupRemoteSlots.count) / \(sources.count) mapped mobile slots connected")
                        .font(.caption)
                    ForEach(studio.groupRemoteSlots.keys.sorted(by:{ $0.uuidString < $1.uuidString }),id:\.self) { id in
                        HStack {
                            Text((studio.groupRemoteSlots[id]?.rawValue ?? "Unknown") + " · " + String(id.uuidString.prefix(8))).font(.caption)
                            Button("Disconnect") { studio.revokeGroupRemote(id) }
                        }
                    }
                    Button("Stop mobile listener") {
                        clearInvitation()
                        studio.stopGroupRemote()
                    }.disabled(studio.groupRemoteEndpoint == nil)
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(4)
        }
        .onAppear { if !sources.contains(source),let first = sources.first { source = first } }
        .onChange(of:studio.groupRemoteSlots) { slots in
            if let invitationSource,slots.values.contains(invitationSource) { clearInvitation(); shareLabels = false }
        }
        .onChange(of:studio.groupRemoteReady) { ready in if !ready { clearInvitation(); shareLabels = false } }
        .onDisappear { clearInvitation(); shareLabels = false; pendingStart = nil; confirmStart = false }
        .confirmationDialog("Start MPE with mobile controllers?",isPresented:$confirmStart,titleVisibility:.visible) {
            Button("Confirm MPE + mobile Start") {
                guard let snapshot = pendingStart else { return }
                pendingStart = nil
                begin(tuned:snapshot)
            }
            Button("Cancel",role:.cancel) { pendingStart = nil }
        } message: {
            Text("This configures separate MPE ports and opens the selected TLS controller listener. Confirm receiver compatibility and the selected network. No standard MIDI fallback.")
        }
    }
}
#endif
