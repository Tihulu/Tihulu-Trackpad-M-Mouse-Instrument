import Foundation

public enum RemoteHostEvent: Sendable {
    case ready
    case invitation(UUID, Data, Double)
    case frame(UUID, Data, Double)
    case disconnected(UUID)
    case fault
}

public enum RemoteHostAction: Equatable, Sendable {
    case acknowledge(UUID, Bool)
    case capabilities(UUID, RemoteCapabilities)
    case mapping(UUID, RemoteMappingPage)
    case mappingLabels(UUID, RemoteMappingLabelPage)
    case revoke(UUID)
    case stop
}

public struct RemoteHostBatch: Sendable {
    public var commands: [SensorCommand] = []
    public var actions: [RemoteHostAction] = []
    public var fault = false
}

/// Main-actor/serial caller owns this value and the existing physical runtime.
/// Transport identifiers are never supplied by the browser. One bridge per
/// listener lifetime; a retired bridge cannot accept more events.
public struct RemoteHostBridge: Sendable {
    private var bindings: [UUID: UUID] = [:]
    public private(set) var ready = false
    public private(set) var stopped = false
    public var connectionIDs: Set<UUID> { Set(bindings.keys) }
    public init() {}

    public mutating func issue(secret: Data, source: SensorSource, now: Double,
                               runtime: inout PhysicalPatchRuntime, mappingDetails: Bool = false, mappingLabels: Bool = false) throws {
        guard ready, !stopped else { throw RemoteTouchError.unavailable }
        try runtime.issueRemotePairing(secret: secret, source: source, now: now, mappingDetails: mappingDetails, mappingLabels: mappingLabels)
    }

    public mutating func revoke(_ connection: UUID, runtime: inout PhysicalPatchRuntime) -> RemoteHostBatch {
        var result = RemoteHostBatch()
        if let peer = bindings.removeValue(forKey: connection) {
            result.commands = runtime.revokeRemote(peer)
        }
        result.actions = [.revoke(connection)]
        return result
    }

    public mutating func stop(runtime: inout PhysicalPatchRuntime) -> RemoteHostBatch {
        stopped = true
        ready = false
        bindings.removeAll()
        var result = RemoteHostBatch()
        result.commands = runtime.disableRemote()
        result.actions = [.stop]
        return result
    }

    public mutating func process(_ events: [RemoteHostEvent], now: Double,
                                 runtime: inout PhysicalPatchRuntime) -> RemoteHostBatch {
        guard !stopped else { return RemoteHostBatch() }
        guard now.isFinite, now >= 0, events.count <= 32,
              !events.contains(where: { if case .fault = $0 { return true }; return false })
        else {
            var result = stop(runtime: &runtime)
            result.fault = true
            return result
        }
        var result = RemoteHostBatch()
        // Expire before processing delayed events. Never resurrect a timed-out peer.
        result.commands += runtime.expire(now: now)
        let expired = bindings.filter { !runtime.remotePeerIDs.contains($0.value) }.map(\.key)
        for id in expired {
            bindings.removeValue(forKey: id)
            result.actions.append(.revoke(id))
        }
        // A disconnected connection cannot emit a queued note from this batch.
        let disconnected = Set(events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id }; return nil
        })
        for id in disconnected.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let peer = bindings.removeValue(forKey: id) { result.commands += runtime.revokeRemote(peer) }
        }
        for event in events {
            switch event {
            case .ready: ready = true
            case .fault, .disconnected: break
            case .invitation(let connection, let secret, let time):
                guard ready, !disconnected.contains(connection), bindings[connection] == nil,
                      !expired.contains(connection), fresh(time, now: now),
                      let peer = try? runtime.admitRemote(secret: secret, now: now)
                else {
                    if let peer = bindings.removeValue(forKey: connection) { result.commands += runtime.revokeRemote(peer) }
                    result.actions.append(.acknowledge(connection, false))
                    continue
                }
                bindings[connection] = peer
                result.actions.append(.acknowledge(connection, true))
            case .frame(let connection, let bytes, let time):
                guard !disconnected.contains(connection), let peer = bindings[connection],
                      fresh(time, now: now) else {
                    if let peer = bindings.removeValue(forKey: connection) { result.commands += runtime.revokeRemote(peer) }
                    result.actions.append(.acknowledge(connection, false))
                    continue
                }
                switch runtime.receiveRemote(peer, bytes: bytes, now: now) {
                case .accepted(let commands):
                    result.commands += commands
                    let frame = try? RemoteTouchFrame.read(bytes)
                    if frame?.kind == .capabilities {
                        if let capabilities = runtime.remoteCapabilities(peer) {
                            result.actions.append(.capabilities(connection, capabilities))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            result.actions.append(.acknowledge(connection, false))
                        }
                    } else if let frame, frame.kind == .mapping {
                        if let index = frame.page,
                           let page = try? runtime.remoteMappingPage(peer,page:index,sequence:frame.sequence) {
                            result.actions.append(.mapping(connection,page))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            result.actions.append(.acknowledge(connection,false))
                        }
                    } else if let frame, frame.kind == .mappingLabels {
                        if let index = frame.page,
                           let page = try? runtime.remoteMappingLabelPage(peer,page:index,sequence:frame.sequence) {
                            result.actions.append(.mappingLabels(connection,page))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            result.actions.append(.acknowledge(connection,false))
                        }
                    } else {
                        result.actions.append(.acknowledge(connection, true))
                    }
                case .close(let commands):
                    result.commands += commands
                    bindings.removeValue(forKey: connection)
                    result.actions.append(.acknowledge(connection, false))
                }
            }
        }
        return result
    }

    private func fresh(_ receipt: Double, now: Double) -> Bool {
        MonotonicReceiptAdmission.permits(receipt:receipt,now:now,maximumAge:0.1)
    }
}
