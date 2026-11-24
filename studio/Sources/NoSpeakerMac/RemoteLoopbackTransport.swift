#if os(macOS)
import Foundation
import Network
import Security
import NoSpeakerCore

/// Explicit numeric local endpoint only. No automatic listener, wildcard or
/// plaintext fallback. The caller selects an existing trusted TLS identity.
/// The host owns R1 admission and MIDI; this transport cannot generate MIDI.
public final class RemoteLoopbackTransport: @unchecked Sendable {
    public enum Failure: Error { case identity, invalidPort, invalidPolicy }
    public typealias Event = RemoteHostEvent
    private struct Peer {
        let connection: NWConnection
        var gate: RemoteConnectionGate
        var awaitingHost = false
    }
    private let queue = DispatchQueue(label: "com.tihulu.remote.loopback")
    private let lock = NSLock()
    private var events: [Event] = []
    private var overflow = false
    // Queue-confined fields:
    private var peers: [UUID: Peer] = [:]
    private var listener: NWListener?
    private var watchdog: DispatchSourceTimer?
    private var stopped = false
    private let params: NWParameters
    private let port: NWEndpoint.Port
    public let endpoint: RemoteEndpoint
    private var attemptStart = 0.0
    private var attempts = 0

    /// OS CSPRNG, no disk writes or logging.
    public static func invitation() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.identity }
        return Data(bytes)
    }

    public init(identity: SecIdentity, endpoint: RemoteEndpoint = .loopback) throws {
        let port: NWEndpoint.Port = 9443
        guard let policy = RemoteHandshakePolicy(authority: endpoint.socketAuthority, origin: endpoint.origin)
        else { throw Failure.invalidPolicy }
        self.endpoint = endpoint
        guard let localIdentity = sec_identity_create(identity) else { throw Failure.identity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        // Bind exactly the selected address, never all interfaces.
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(endpoint.host), port: port)
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = RemoteTouchFrame.maximumBytes
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { protocols, headers in
            let ok = policy.permits(protocols: protocols, headers: headers)
            return .init(status: ok ? .accept : .reject,
                         subprotocol: ok ? RemoteHandshakePolicy.subprotocol : nil,
                         additionalHeaders: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        self.params = parameters
        self.port = port
    }

    public func start() {
        queue.async { [self] in
            guard !stopped, listener == nil else { return }
            do {
                let server = try NWListener(using: params, on: port)
                listener = server
                server.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.push(.ready)
                    case .failed: self.shutdown(fault: true)
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.expire() }
                watchdog = timer
                timer.resume()
                server.start(queue: queue)
            } catch { shutdown(fault: true) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now-attemptStart >= 60 { attemptStart = now; attempts = 0 }
        guard !stopped, peers.count < 6, attempts < 24 else { connection.cancel(); return }
        attempts += 1
        let id = UUID()
        peers[id] = Peer(connection: connection, gate: .init(now: now))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive(id)
            case .failed, .cancelled: self.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ id: UUID) {
        guard let peer = peers[id], !peer.awaitingHost else { return }
        peer.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, var peer = self.peers[id] else { return }
            guard error == nil, let data, !data.isEmpty,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            else { self.close(id); return }
            let now = ProcessInfo.processInfo.systemUptime
            let event: Event
            if peer.gate.phase == .pending {
                guard peer.gate.receiveInvitation(data, binary: metadata.opcode == .binary, now: now)
                else { self.close(id); return }
                event = .invitation(id, data, now)
            } else {
                guard peer.gate.receiveFrame(data, text: metadata.opcode == .text, now: now)
                else { self.close(id); return }
                event = .frame(id, data, now)
            }
            peer.awaitingHost = true
            self.peers[id] = peer
            self.push(event)
            // At most one unacknowledged data event per peer.
        }
    }

    /// Host must consume invitation via R1 before accepting; acknowledge each
    /// processed frame only after R1 accepts it. A false result closes the peer.
    public func acknowledge(_ id: UUID, accepted: Bool, capabilities: RemoteCapabilities? = nil, mapping: RemoteMappingPage? = nil, labels: RemoteMappingLabelPage? = nil) {
        queue.async { [self] in
            guard var peer = peers[id], peer.awaitingHost else { return }
            guard accepted, [capabilities != nil,mapping != nil,labels != nil].filter({ $0 }).count <= 1 else { close(id); return }
            let message: String
            if peer.gate.phase == .awaitingHost {
                guard peer.gate.admit(now: ProcessInfo.processInfo.systemUptime) else { close(id); return }
                guard capabilities == nil, mapping == nil, labels == nil else { close(id); return }
                message = "admitted"
            } else if let capabilities {
                guard let payload = try? capabilities.encoded(), let json = String(data: payload, encoding: .utf8) else { close(id); return }
                message = json
            } else if let mapping {
                guard let payload = try? mapping.encoded(), let json = String(data: payload, encoding: .utf8) else { close(id); return }
                message = json
            } else if let labels {
                guard let payload = try? labels.encoded(), let json = String(data: payload, encoding: .utf8) else { close(id); return }
                message = json
            } else {
                message = "accepted"
            }
            peers[id] = peer
            // Only acknowledge after host admission/delivery. Keep one frame
            // outstanding until this small acknowledgment is processed.
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: message, metadata: [metadata])
            peer.connection.send(content: Data(message.utf8), contentContext: context,
                                 isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self, var current = self.peers[id] else { return }
                guard error == nil else { self.close(id); return }
                current.awaitingHost = false
                self.peers[id] = current
                self.receive(id)
            })
        }
    }

    public func revoke(_ id: UUID) { queue.async { [self] in close(id) } }

    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        for id in peers.filter({ $0.value.gate.expired(now: now) }).map(\.key) { close(id) }
    }

    private func close(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
        push(.disconnected(id))
    }

    public func drain() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
    }

    private func push(_ event: Event) {
        lock.lock()
        if overflow { lock.unlock(); return }
        if events.count >= 32 {
            overflow = true
            events = [.fault]
            lock.unlock()
            shutdown(fault: false)
            return
        }
        events.append(event)
        lock.unlock()
    }

    public func stop() { queue.async { [self] in shutdown(fault: false) } }

    private func shutdown(fault: Bool) {
        guard !stopped else { return }
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) { close(id) }
        if fault { push(.fault) }
    }
}
#endif
