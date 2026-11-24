#if os(macOS)
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import NoSpeakerCore
import NoSpeakerMac

struct RemoteLoopbackPanel: View {
    @EnvironmentObject private var studio: StudioController
    let patch: InstrumentPatch
    let sendMIDI: Bool
    @State private var identities: [RemoteTLSIdentityChoice] = []
    @State private var selected: UUID?
    @State private var source: SensorSource = .phone
    @State private var message = ""
    @State private var invitation = ""
    @State private var shareMappingDetails = false
    @State private var shareMappingLabels = false
    @State private var invitationSharesLabels = false
    @State private var invitationSharesMapping = false
    @State private var lan = false
    @State private var lanChoices: [RemoteLANChoice] = []
    @State private var selectedLAN: String?
    @State private var confirmedLAN = false
    private var endpoint: RemoteEndpoint? {
        lan ? lanChoices.first(where: { $0.id == selectedLAN })?.endpoint : .loopback
    }
    @State private var clearTask: Task<Void, Never>?
    private var sources: [SensorSource] {
        [.phone,.tablet].filter { kind in patch.routes.contains { $0.source == kind } }
    }

    var body: some View {
        GroupBox("Remote · TLS controller") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Experimental. Requires a dedicated trusted TLS identity for the selected address. No automatic certificate installation or trust bypass. Run a successful Mac-only diagnostic before enabling LAN in this app session.")
                    .font(.caption).foregroundStyle(.secondary)
                if !studio.patchRunning {
                    Toggle("Enable experimental LAN (trusted private network only)", isOn: $lan)
                        .disabled(!studio.remoteLoopbackVerified)
                        .onChange(of: lan) { _ in confirmedLAN = false }
                    if !studio.remoteLoopbackVerified {
                        Text("LAN is locked until the local TLS, pairing and source-aware protocol diagnostic succeeds.").font(.caption)
                    }
                    if lan {
                        HStack {
                            Button("Refresh local addresses") {
                                lanChoices = RemoteLANChoice.available()
                                selectedLAN = nil
                                confirmedLAN = false
                            }
                            Picker("Bind address", selection: $selectedLAN) {
                                Text("Choose interface").tag(String?.none)
                                ForEach(lanChoices) { choice in
                                    Text(choice.interface + " · " + choice.endpoint.host).tag(Optional(choice.id))
                                }
                            }.onChange(of: selectedLAN) { _ in confirmedLAN = false }
                        }
                        Toggle("I trust this network and the phone trusts the matching TLS certificate", isOn: $confirmedLAN)
                        Text("Do not forward ports or ignore certificate warnings. Phone trust must be provisioned separately. Only the selected private IPv4 address is bound.").font(.caption)
                    }
                    HStack {
                        Button("Load Keychain identities") {
                            do {
                                identities = try RemoteTLSIdentityChoice.available()
                                selected = nil
                                message = identities.isEmpty ? "No identities found. See Remote R2c setup notes." : "Select your dedicated local TLS identity."
                            } catch { message = error.localizedDescription }
                        }
                        Picker("TLS identity", selection: $selected) {
                            Text("Choose identity").tag(UUID?.none)
                            ForEach(identities) { choice in Text(choice.name).tag(Optional(choice.id)) }
                        }
                    }
                    Button(lan ? "Start LAN listener" : "Start loopback listener") {
                        guard let choice = identities.first(where: { $0.id == selected }), let endpoint else { return }
                        if lan && (!studio.remoteLoopbackVerified || !confirmedLAN || !RemoteLANChoice.available().contains(where: { $0.id == selectedLAN && $0.endpoint == endpoint })) {
                            message = "Select and confirm a current private LAN address."; return
                        }
                        do {
                            let transport = try choice.makeLoopbackTransport(endpoint: endpoint)
                            let page = try choice.makeLoopbackPageServer(endpoint: endpoint)
                            studio.updateInstrumentPatch(patch)
                            studio.startInstrumentPatch(sendMIDI: sendMIDI, physical: true, remoteTransport: transport, remotePage: page)
                            message = ""
                        } catch { message = error.localizedDescription }
                    }.disabled(selected == nil || endpoint == nil || (lan && (!confirmedLAN || !studio.remoteLoopbackVerified)) || !PhysicalPatchRuntime.supports(patch, allowRemote: true))
                    Text(sendMIDI ? "MIDI ON: if XY is mapped, diagnostic touch may sound notes. Use a separate DAW instrument." :
                         "MIDI OFF: mapped diagnostic touch commands appear in the monitor without sending to DAW. Non-XY sources use an idle heartbeat.")
                        .font(.caption)
                } else {
                    Text(studio.patchRemoteReady ? "Remote listener ready" : "Remote listener not ready").font(.headline)
                    Picker("Test source", selection: $source) {
                        ForEach(sources, id: \.self) { Text($0.rawValue).tag($0) }
                    }.disabled(studio.patchRemoteProbeRunning)
                    Button("Run TLS + source diagnostic") {
                        clearInvitation()
                        studio.runBuilderRemoteProbe(source: source)
                    }
                        .disabled(!studio.patchRemoteReady || studio.patchRemoteProbeRunning || !sources.contains(source) || studio.patchRemoteEndpoint?.isLoopback != true)
                    Text(studio.patchRemoteProbeStatus).font(.caption)
                    Divider()
                    Text(studio.patchRemotePageReady ? "HTTPS controller ready" : "HTTPS controller not ready").font(.caption)
                    if studio.patchRemotePageReady, let endpoint = studio.patchRemoteEndpoint {
                        Text(endpoint.pageURL).font(.caption.monospacedDigit()).textSelection(.enabled)
                        Button("Open browser controller on this Mac") {
                            if let url = URL(string: endpoint.pageURL) { NSWorkspace.shared.open(url) }
                        }
                        if !endpoint.isLoopback, let image = qrImage(endpoint.pageURL) {
                            Image(nsImage: image).interpolation(.none).resizable()
                                .frame(width: 160, height: 160)
                                .accessibilityLabel("QR code for controller page address")
                            Text("Scan the page address on your phone. Enter the separate invitation; QR contains no secret.").font(.caption)
                        }
                    }
                    Toggle("Share MIDI destination details with this invitation", isOn: $shareMappingDetails)
                        .disabled(!invitation.isEmpty || !studio.patchRemoteReady || !studio.patchRemotePageReady || studio.patchRemoteProbeRunning || !sources.contains(source))
                    Toggle("Also share custom control labels", isOn: $shareMappingLabels)
                        .disabled(!shareMappingDetails || !invitation.isEmpty)
                    Text("Custom labels can contain user-entered text. Only share with a trusted paired device.").font(.caption)
                    Text("Off by default. If enabled, the paired device can read its mapped MIDI channels, notes and controls. Other device mappings and patch names are not shared. Disconnect the peer to withdraw access; already disclosed information cannot be recalled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create one-time browser invitation") {
                        let consent = shareMappingDetails
                        let labels = consent && shareMappingLabels
                        clearInvitation()
                        do {
                            invitation = try studio.issueBuilderRemoteInvitation(source: source, mappingDetails: consent, mappingLabels: labels)
                                .map { String(format: "%02x", $0) }.joined()
                            invitationSharesMapping = consent
                            invitationSharesLabels = labels
                            clearTask = Task {
                                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                                clearInvitation()
                            }
                        } catch { message = "Could not create invitation." }
                    }.disabled(!studio.patchRemoteReady || !studio.patchRemotePageReady || studio.patchRemoteProbeRunning || !sources.contains(source))
                    if !invitation.isEmpty {
                        Text(invitationSharesMapping ? "This invitation shares MIDI destination details." : "This invitation keeps MIDI destination details hidden.")
                            .font(.caption)
                        Text(invitationSharesLabels ? "Custom labels shared." : "Custom labels hidden.").font(.caption)
                        Text(invitation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Enter into the controller page within 60 seconds. Treat this invitation as a password.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Cancel invitation") { clearInvitation() }
                    }
                    Text("Admitted clients: \(studio.patchRemotePeers.count)").font(.caption)
                    ForEach(Array(studio.patchRemotePeers).sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        HStack {
                            Text("Peer " + String(id.uuidString.prefix(8))).font(.caption.monospacedDigit())
                            Button("Disconnect") { studio.revokeBuilderRemote(id) }
                        }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(6)
        }.onDisappear { clearInvitation() }
        .onChange(of: studio.patchRunning) { running in if !running { clearInvitation() } }
        .onChange(of: studio.patchRemotePeers) { _ in if !invitation.isEmpty { clearInvitation() } }
        .onChange(of: source) { _ in clearInvitation() }
        .onChange(of: shareMappingDetails) { enabled in if !enabled { shareMappingLabels = false } }
        .onAppear {
            if !sources.contains(source), let first = sources.first { source = first }
        }.onChange(of: sources) { available in
            if !available.contains(source), let first = available.first { source = first }
        }
    }

    private func qrImage(_ url: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private func clearInvitation() {
        clearTask?.cancel(); clearTask = nil
        invitation = ""
        shareMappingDetails = false
        shareMappingLabels = false
        invitationSharesMapping = false
        invitationSharesLabels = false
        studio.cancelBuilderRemoteInvitation()
    }
}
#endif
