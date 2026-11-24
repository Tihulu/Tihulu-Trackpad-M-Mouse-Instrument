#if os(macOS)
import SwiftUI
import AppKit
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
    @State private var clearTask: Task<Void, Never>?
    private var sources: [SensorSource] {
        [.phone,.tablet].filter { kind in patch.routes.contains { $0.source == kind } }
    }

    var body: some View {
        GroupBox("Remote · Mac-only TLS diagnostic") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Experimental loopback only. Requires an existing trusted TLS identity for 127.0.0.1. Includes a local browser test page, not LAN or phone access. No certificate installation or trust bypass.")
                    .font(.caption).foregroundStyle(.secondary)
                if !studio.patchRunning {
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
                    Button("Start loopback listener") {
                        guard let choice = identities.first(where: { $0.id == selected }) else { return }
                        do {
                            let transport = try choice.makeLoopbackTransport()
                            let page = try choice.makeLoopbackPageServer()
                            studio.updateInstrumentPatch(patch)
                            studio.startInstrumentPatch(sendMIDI: sendMIDI, physical: true, remoteTransport: transport, remotePage: page)
                            message = ""
                        } catch { message = error.localizedDescription }
                    }.disabled(selected == nil || !PhysicalPatchRuntime.supports(patch, allowRemote: true))
                    Text(sendMIDI ? "MIDI ON: diagnostic touch may sound mapped notes. Use a separate DAW instrument." :
                         "MIDI OFF: diagnostic commands appear in the monitor without sending to DAW.")
                        .font(.caption)
                } else {
                    Text(studio.patchRemoteReady ? "Loopback listener ready" : "No ready loopback listener").font(.headline)
                    Picker("Test source", selection: $source) {
                        ForEach(sources, id: \.self) { Text($0.rawValue).tag($0) }
                    }.disabled(studio.patchRemoteProbeRunning)
                    Button("Run TLS + touch/release test") {
                        clearInvitation()
                        studio.runBuilderRemoteProbe(source: source)
                    }
                        .disabled(!studio.patchRemoteReady || studio.patchRemoteProbeRunning || !sources.contains(source))
                    Text(studio.patchRemoteProbeStatus).font(.caption)
                    Divider()
                    Text(studio.patchRemotePageReady ? "HTTPS controller ready" : "HTTPS controller not ready").font(.caption)
                    Button("Open local browser controller") {
                        if let url = URL(string: "https://127.0.0.1:9444/") { NSWorkspace.shared.open(url) }
                    }.disabled(!studio.patchRemotePageReady)
                    Button("Create one-time browser invitation") {
                        clearInvitation()
                        do {
                            invitation = try studio.issueBuilderRemoteInvitation(source: source)
                                .map { String(format: "%02x", $0) }.joined()
                            clearTask = Task {
                                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                                clearInvitation()
                            }
                        } catch { message = "Could not create invitation." }
                    }.disabled(!studio.patchRemoteReady || !studio.patchRemotePageReady || studio.patchRemoteProbeRunning || !sources.contains(source))
                    if !invitation.isEmpty {
                        Text(invitation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Paste into the local page within 60 seconds. Treat this invitation as a password.")
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
        .onAppear {
            if !sources.contains(source), let first = sources.first { source = first }
        }.onChange(of: sources) { available in
            if !available.contains(source), let first = available.first { source = first }
        }
    }

    private func clearInvitation() {
        clearTask?.cancel(); clearTask = nil
        invitation = ""
        studio.cancelBuilderRemoteInvitation()
    }
}
#endif
