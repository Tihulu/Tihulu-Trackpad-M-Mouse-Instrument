import Foundation

public struct PerformanceGroupRemoteBatch: Sendable {
    public var reports:[PerformanceGroupDelivery.Report] = []
    public var actions:[RemoteHostAction] = []
    public var fault = false
    public init() {}
}

/// Serial host-owned bridge over the established RemoteHostEvent transport.
/// It never opens a socket. An invitation selects an existing logical slot,
/// not a browser-provided source or destination. No MIDI destination disclosure.
public struct PerformanceGroupRemoteBridge: Sendable {
    private struct Connection: Sendable {
        let source:SensorSource
        let token:UUID
        var capabilitiesSeen = false
        var mappingComplete = false
        var performanceStarted = false
        var labels:[RemoteMappingLabel] = []
        var nextLabelPage = 0
        var labelsComplete = false
        var metadataStartedAt:Double?
    }
    private var pairing = RemotePairingGate()
    private var invitationIssuedAt:Double?
    private var invitationSharesLabels = false
    private var bindings:[UUID:Connection] = [:]
    public private(set) var ready = false
    public private(set) var stopped = false
    public var connectionIDs:Set<UUID> { Set(bindings.keys) }
    /// Host-only slot association; never serialized to paired devices.
    public var connectionSlots:[UUID:SensorSource] { bindings.mapValues { $0.source } }
    public init() {}

    public mutating func issue(secret:Data,source:SensorSource,now:Double,
                               session:PerformanceGroupGamepadSession,shareLabels:Bool = false) throws {
        guard ready,!stopped,!session.retired,session.remoteSlots.contains(source),
              !session.boundSources.contains(source),
              !bindings.values.contains(where:{ $0.source == source }) else { throw RemoteTouchError.unavailable }
        try pairing.issue(secret:secret,source:source,now:now,allowGroupSlots:true)
        invitationIssuedAt = now
        invitationSharesLabels = shareLabels
    }

    public mutating func cancelInvitation() {
        pairing.clear()
        invitationIssuedAt = nil
        invitationSharesLabels = false
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
        let disconnected = Set(events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id }; return nil
        })
        var departing:[SensorSource:UUID] = [:]
        for id in disconnected {
            if let binding = bindings.removeValue(forKey:id) { departing[binding.source] = binding.token }
        }
        result.reports += session.expire(now:now,removingRemote:departing,send:send)
        let expired = Set(bindings.compactMap { id,binding in
            session.matchesRemoteBinding(binding.source,token:binding.token) ? nil : id
        })
        var rejected = expired.union(disconnected)
        for id in expired.sorted(by:{ $0.uuidString < $1.uuidString }) {
            bindings.removeValue(forKey:id)
            result.actions.append(.revoke(id))
        }
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
                let shareLabels = invitationSharesLabels
                cancelInvitation()
                guard session.remoteSlots.contains(source),
                      let token = try? session.bind(source,now:now) else {
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                bindings[id] = Connection(source:source,token:token,labels:shareLabels ? session.groupRemoteLabels(source) : [])
                result.actions.append(.acknowledge(id,true))
            case .frame(let id,let bytes,let receipt):
                guard !rejected.contains(id),var binding = bindings[id],
                      fresh(receipt,now:now),let validated = try? ValidatedGroupRemoteFrame(bytes:bytes) else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                let frame = validated.frame
                // Redacted destination page, then optional consented label pages.
                // No metadata refresh during or after musical performance.
                let withinBudget = binding.metadataStartedAt.map { now-$0 < 10 } ?? true
                let metadataAllowed:Bool
                switch frame.kind {
                case .capabilities:
                    metadataAllowed = !binding.capabilitiesSeen && !binding.performanceStarted
                case .mapping:
                    metadataAllowed = withinBudget && binding.capabilitiesSeen && !binding.mappingComplete &&
                        !binding.performanceStarted && frame.page == 0
                case .mappingLabels:
                    metadataAllowed = withinBudget && binding.mappingComplete && !binding.labelsComplete &&
                        !binding.performanceStarted && frame.page == binding.nextLabelPage
                default:
                    // Direct core clients may omit metadata entirely. Once
                    // the label sequence begins, it must finish before play.
                    metadataAllowed = binding.nextLabelPage == 0 || binding.labelsComplete
                }
                guard metadataAllowed else {
                    result.reports += remove([id],session:&session,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                let received = session.receiveRemoteValidated(binding.source,token:binding.token,validated:validated,
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
                    binding.metadataStartedAt = now
                    result.actions.append(.capabilities(id,capabilities))
                case .mapping:
                    binding.mappingComplete = true
                    result.actions.append(.mapping(id,.init(sequence:frame.sequence,page:0,pages:1,total:0,detail:false,rows:[])))
                case .mappingLabels:
                    let page = binding.nextLabelPage
                    let total = binding.labels.count
                    let pages = max(1,total)
                    let response = RemoteMappingLabelPage(sequence:frame.sequence,page:page,pages:pages,total:total,
                        rows:total == 0 ? [] : [binding.labels[page]])
                    binding.nextLabelPage += 1
                    binding.labelsComplete = binding.nextLabelPage == pages
                    result.actions.append(.mappingLabels(id,response))
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
