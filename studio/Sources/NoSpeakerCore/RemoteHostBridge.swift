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
    /// Oldest wire receipt contributing accepted performance commands.
    /// The flattened Builder batch must not outlive that receipt. Cleanup
    /// without accepted frame output has no new performance receipt.
    public private(set) var deliveryReceipt:Double?
    public var actions: [RemoteHostAction] = []
    public var fault = false
    mutating func appendFrameCommands(_ commands:[SensorCommand],receipt:Double) {
        guard !commands.isEmpty else { return }
        deliveryReceipt=min(deliveryReceipt ?? receipt,receipt)
        self.commands += commands
    }
}

/// Main-actor/serial caller owns this value and the existing physical runtime.
/// Transport identifiers are never supplied by the browser. One bridge per
/// listener lifetime; a retired bridge cannot accept more events.
public struct RemoteHostBridge: Sendable {
    private var bindings: [UUID: UUID] = [:]
    private var invitationIssuedAt:Double?
    public private(set) var ready = false
    public private(set) var stopped = false
    public var connectionIDs: Set<UUID> { Set(bindings.keys) }
    public init() {}

    public mutating func issue(secret: Data, source: SensorSource, now: Double,
                               runtime: inout PhysicalPatchRuntime, mappingDetails: Bool = false, mappingLabels: Bool = false) throws {
        guard ready, !stopped else { throw RemoteTouchError.unavailable }
        try runtime.issueRemotePairing(secret: secret, source: source, now: now, mappingDetails: mappingDetails, mappingLabels: mappingLabels)
        invitationIssuedAt = now
    }

    public mutating func revoke(_ connection: UUID, runtime: inout PhysicalPatchRuntime) -> RemoteHostBatch {
        var result = RemoteHostBatch()
        if let peer = bindings.removeValue(forKey: connection) {
            result.commands = runtime.revokeRemote(peer)
        }
        result.actions = [.revoke(connection)]
        return result
    }

    /// Native host uses a current clock so explicit revocation cannot
    /// restore a second owner whose deadline has already passed.
    public mutating func revoke(_ connection:UUID,now:Double,
                                runtime:inout PhysicalPatchRuntime) -> RemoteHostBatch {
        guard now.isFinite,now>=0 else {
            var result=stop(runtime:&runtime)
            result.fault=true
            return result
        }
        guard let peer=bindings.removeValue(forKey:connection) else {
            var result=RemoteHostBatch()
            result.actions=[.revoke(connection)]
            return result
        }
        var result=RemoteHostBatch()
        result.commands=runtime.expire(now:now,removingRemote:[peer])
        result.actions=[.revoke(connection)]
        let expired=bindings.filter { !runtime.remotePeerIDs.contains($0.value) }.map(\.key)
        for id in expired.sorted(by:{ $0.uuidString < $1.uuidString }) {
            bindings.removeValue(forKey:id)
            result.actions.append(.revoke(id))
        }
        return result
    }

    public mutating func stop(runtime: inout PhysicalPatchRuntime) -> RemoteHostBatch {
        stopped = true
        ready = false
        bindings.removeAll()
        invitationIssuedAt = nil
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
        // Remove known transport departures and expired owners together.
        let disconnected = Set(events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id }; return nil
        })
        let departures = Set(disconnected.compactMap { bindings.removeValue(forKey:$0) })
        result.commands += runtime.expire(now:now,removingRemote:departures)
        let expired = Set(bindings.filter { !runtime.remotePeerIDs.contains($0.value) }.map(\.key))
        var rejected = disconnected.union(expired)
        for id in expired.sorted(by:{ $0.uuidString < $1.uuidString }) {
            bindings.removeValue(forKey: id)
            result.actions.append(.revoke(id))
        }
        for event in events {
            switch event {
            case .ready: ready = true
            case .fault, .disconnected: break
            case .invitation(let connection, let secret, let time):
                guard ready, !rejected.contains(connection), bindings[connection] == nil,
                      fresh(time, now: now),let issued = invitationIssuedAt,time >= issued,
                      let peer = try? runtime.admitRemote(secret: secret, receipt:time,now:now)
                else {
                    if let peer = bindings.removeValue(forKey: connection) { result.commands += runtime.revokeRemote(peer) }
                    rejected.insert(connection)
                    result.actions.append(.acknowledge(connection, false))
                    continue
                }
                invitationIssuedAt = nil
                bindings[connection] = peer
                result.actions.append(.acknowledge(connection, true))
            case .frame(let connection, let bytes, let time):
                guard !rejected.contains(connection), let peer = bindings[connection],
                      fresh(time, now: now) else {
                    if let peer = bindings.removeValue(forKey: connection) { result.commands += runtime.revokeRemote(peer) }
                    rejected.insert(connection)
                    result.actions.append(.acknowledge(connection, false))
                    continue
                }
                switch runtime.receiveRemote(peer, bytes: bytes, receipt:time,now:now) {
                case .accepted(let commands):
                    result.appendFrameCommands(commands,receipt:time)
                    let frame = try? RemoteTouchFrame.read(bytes)
                    if frame?.kind == .capabilities {
                        if let capabilities = runtime.remoteCapabilities(peer) {
                            result.actions.append(.capabilities(connection, capabilities))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            rejected.insert(connection)
                            result.actions.append(.acknowledge(connection, false))
                        }
                    } else if let frame, frame.kind == .mapping {
                        if let index = frame.page,
                           let page = try? runtime.remoteMappingPage(peer,page:index,sequence:frame.sequence) {
                            result.actions.append(.mapping(connection,page))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            rejected.insert(connection)
                            result.actions.append(.acknowledge(connection,false))
                        }
                    } else if let frame, frame.kind == .mappingLabels {
                        if let index = frame.page,
                           let page = try? runtime.remoteMappingLabelPage(peer,page:index,sequence:frame.sequence) {
                            result.actions.append(.mappingLabels(connection,page))
                        } else {
                            result.commands += runtime.revokeRemote(peer)
                            bindings.removeValue(forKey: connection)
                            rejected.insert(connection)
                            result.actions.append(.acknowledge(connection,false))
                        }
                    } else {
                        result.actions.append(.acknowledge(connection, true))
                    }
                case .close(let commands):
                    result.commands += commands
                    bindings.removeValue(forKey: connection)
                    rejected.insert(connection)
                    result.actions.append(.acknowledge(connection, false))
                }
            }
        }
        // Metadata is published only after the batch returns. Do not
        // disclose a queued response to a connection retired in this batch.
        result.actions.removeAll { action in
            switch action {
            case .capabilities(let id,_),.mapping(let id,_),.mappingLabels(let id,_):
                return bindings[id] == nil
            default: return false
            }
        }
        return result
    }

    private func fresh(_ receipt: Double, now: Double) -> Bool {
        MonotonicReceiptAdmission.permits(receipt:receipt,now:now,maximumAge:0.1)
    }
}
