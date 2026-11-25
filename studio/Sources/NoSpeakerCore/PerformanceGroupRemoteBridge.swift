import Foundation

public struct PerformanceGroupRemoteBatch: Sendable {
    public var reports:[PerformanceGroupDelivery.Report] = []
    public var actions:[RemoteHostAction] = []
    public var fault = false
}

/// Serial host-owned bridge over the established RemoteHostEvent transport.
/// It never opens a socket. An invitation selects an existing logical slot,
/// not a browser-provided source or destination. No mapping disclosure.
public struct PerformanceGroupRemoteBridge: Sendable {
    private struct Connection: Sendable {
        let source:SensorSource
        let token:UUID
        var capabilitiesSeen = false
        var mappingComplete = false
        var performanceStarted = false
    }
    private var pairing = RemotePairingGate()
    private var invitationIssuedAt:Double?
    private var bindings:[UUID:Connection] = [:]
    public private(set) var ready = false
    public private(set) var stopped = false
    public var connectionIDs:Set<UUID> { Set(bindings.keys) }
    public init() {}

    public mutating func issue(secret:Data,source:SensorSource,now:Double,
                               session:PerformanceGroupGamepadSession) throws {
        guard ready,!stopped,!session.retired,session.remoteSlots.contains(source),
              !session.boundSources.contains(source),
              !bindings.values.contains(where:{ $0.source == source }) else { throw RemoteTouchError.unavailable }
        try pairing.issue(secret:secret,source:source,now:now)
        invitationIssuedAt = now
    }

    public mutating func cancelInvitation() {
        pairing.clear()
        invitationIssuedAt = nil
    }

    public mutating func revoke(_ connection:UUID,session:inout PerformanceGroupGamepadSession,
                                send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        var result = PerformanceGroupRemoteBatch()
        result.reports = remove([connection],session:&session,send:send)
        result.actions = [.revoke(connection)]
        return result
    }

    public mutating func stop(session:inout PerformanceGroupGamepadSession,
                              send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        stopped = true
        ready = false
        cancelInvitation()
        var result = PerformanceGroupRemoteBatch()
        result.reports = remove(Set(bindings.keys),session:&session,send:send)
        result.actions = [.stop]
        return result
    }

    public mutating func process(_ events:[RemoteHostEvent],now:Double,
                                 session:inout PerformanceGroupGamepadSession,
                                 send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        guard !stopped else { return .init() }
        guard now.isFinite,now >= 0,events.count <= 32,
              !events.contains(where:{ if case .fault = $0 { return true }; return false }) else {
            var result = stop(session:&session,send:send)
            result.fault = true
            return result
        }
        if session.retired { return stop(session:&session,send:send) }
        var result = PerformanceGroupRemoteBatch()
        result.reports += session.expire(now:now,send:send)
        let expired = Set(bindings.compactMap { id,binding in
            session.matchesRemoteBinding(binding.source,token:binding.token) ? nil : id
        })
        var rejected = expired
        for id in expired.sorted(by:{ $0.uuidString < $1.uuidString }) {
            bindings.removeValue(forKey:id)
            result.actions.append(.revoke(id))
        }
        let disconnected = Set(events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id }; return nil
        })
        rejected.formUnion(disconnected)
        result.reports += remove(disconnected,session:&session,send:send)
        for event in events {
            switch event {
            case .ready: ready = true
            case .disconnected,.fault: break
            case .invitation(let id,let secret,let receipt):
                guard ready,!rejected.contains(id),bindings[id] == nil,
                      fresh(receipt,now:now),
                      let issued = invitationIssuedAt,receipt >= issued,
                      let source = try? pairing.consume(secret:secret,now:now) else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                invitationIssuedAt = nil
                guard session.remoteSlots.contains(source),
                      let token = try? session.bind(source,now:now) else {
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                bindings[id] = Connection(source:source,token:token)
                result.actions.append(.acknowledge(id,true))
            case .frame(let id,let bytes,let receipt):
                guard !rejected.contains(id),var binding = bindings[id],
                      fresh(receipt,now:now),let frame = try? RemoteTouchFrame.read(bytes) else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                // V8 response is deliberately redacted. A client may request
                // one page after capabilities and before performance only.
                let metadataAllowed = frame.kind != .mapping ||
                    (binding.capabilitiesSeen && !binding.mappingComplete &&
                     !binding.performanceStarted && frame.page == 0)
                guard metadataAllowed,frame.kind != .mappingLabels else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                let received = session.receiveRemote(binding.source,token:binding.token,bytes:bytes,
                                                     hostTime:receipt,now:now,send:send)
                result.reports += received.reports
                guard received.status == .ready || received.status == .waitingForNeutral || received.status == .delivered else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                switch frame.kind {
                case .capabilities:
                    guard let capabilities = session.remoteCapabilities(binding.source) else {
                        result.reports += remove([id],session:&session,send:send)
                        rejected.insert(id)
                        result.actions.append(.acknowledge(id,false))
                        continue
                    }
                    binding.capabilitiesSeen = true
                    result.actions.append(.capabilities(id,capabilities))
                case .mapping:
                    binding.mappingComplete = true
                    result.actions.append(.mapping(id,.init(sequence:frame.sequence,page:0,pages:1,total:0,detail:false,rows:[])))
                case .heartbeat:
                    result.actions.append(.acknowledge(id,true))
                default:
                    binding.performanceStarted = true
                    result.actions.append(.acknowledge(id,true))
                }
                bindings[id] = binding
            }
        }
        return result
    }

    private mutating func remove(_ ids:Set<UUID>,session:inout PerformanceGroupGamepadSession,
                                 send:(PerformanceGroupCommand)->Bool) -> [PerformanceGroupDelivery.Report] {
        var tokens:[SensorSource:UUID] = [:]
        for id in ids {
            if let binding = bindings.removeValue(forKey:id) { tokens[binding.source] = binding.token }
        }
        return session.unbindRemoteBatch(tokens,send:send)
    }

    private func fresh(_ receipt:Double,now:Double) -> Bool {
        receipt.isFinite && receipt >= 0 && receipt <= now && now-receipt < 0.1
    }
}
