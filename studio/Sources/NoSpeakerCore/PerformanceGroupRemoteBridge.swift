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

        // A partial negotiation cannot be kept alive beyond its original
        // budget by heartbeat or additional label pages. Optional metadata
        // omitted by a client that has started performance is not pending.
        func metadataExpired(now:Double)->Bool {
            guard let started=metadataStartedAt,!performanceStarted else { return false }
            let incomplete = !mappingComplete || (nextLabelPage>0 && !labelsComplete)
            return incomplete && now-started>=10
        }
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

    public mutating func revoke(_ connection:UUID,session:inout PerformanceGroupGamepadSession,refreshNow:(()->Double)? = nil,
                                send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        var result = PerformanceGroupRemoteBatch()
        result.reports = remove([connection],session:&session,refreshNow:refreshNow,send:send)
        result.actions = [.revoke(connection)]
        result.actions += reconcileRevoked(session:session)
        return result
    }

    public mutating func stop(session:inout PerformanceGroupGamepadSession,refreshNow:(()->Double)? = nil,
                              send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        stopped = true
        ready = false
        cancelInvitation()
        var result = PerformanceGroupRemoteBatch()
        result.reports = remove(Set(bindings.keys),session:&session,refreshNow:refreshNow,send:send)
        result.actions = [.stop]
        return result
    }

    public mutating func process(_ events:[RemoteHostEvent],now:Double,
                                 refreshNow:(()->Double)? = nil,
                                 session:inout PerformanceGroupGamepadSession,
                                 send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        guard !stopped else { return .init() }
        guard now.isFinite,now>=session.observedHostClock else {
            return retireClockFault(.init(),session:&session,send:send)
        }
        guard events.count <= 32,
              !events.contains(where:{ if case .fault = $0 { return true }; return false }) else {
            var result = stop(session:&session,refreshNow:refreshNow,send:send)
            result.fault = true
            return result
        }
        if session.retired { return stop(session:&session,refreshNow:refreshNow,send:send) }
        var result = PerformanceGroupRemoteBatch()
        // Observe every nested clock read, including those inside session
        // expiry and synchronous restoration fences. A transient regression
        // must remain a fault even if the next sample recovers.
        var highWater=now
        var clockFault=false
        let trackedClock:(()->Double)? = refreshNow.map { sample in
            return {
                guard !clockFault else { return .nan }
                let current=sample()
                guard current.isFinite,current>=highWater else {
                    clockFault=true
                    return .nan
                }
                highWater=current
                return current
            }
        }
        let disconnected = Set(events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id }; return nil
        })
        // Retire timed-out negotiations even on an empty watchdog tick,
        // atomically with known disconnects and existing source expiry.
        let metadataExpired=Set(bindings.compactMap { id,binding in
            binding.metadataExpired(now:now) ? id : nil
        })
        var departing:[SensorSource:UUID] = [:]
        for id in disconnected.union(metadataExpired) {
            if let binding = bindings.removeValue(forKey:id) { departing[binding.source] = binding.token }
        }
        result.reports += session.expire(now:now,removingRemote:departing,refreshNow:trackedClock,send:send)
        let expired = Set(bindings.compactMap { id,binding in
            session.matchesRemoteBinding(binding.source,token:binding.token) ? nil : id
        })
        let revoked=expired.union(metadataExpired.subtracting(disconnected))
        var rejected = revoked.union(disconnected)
        for id in revoked.sorted(by:{ $0.uuidString < $1.uuidString }) {
            bindings.removeValue(forKey:id)
            result.actions.append(.revoke(id))
        }
        guard !clockFault else { return retireClockFault(result,session:&session,send:send) }
        var lastProcessingTime=now
        for event in events {
            // Expiry/disconnect cleanup and earlier frames synchronously
            // invoke the sink. Never reuse the batch-start receipt budget.
            let eventNow=trackedClock?() ?? now
            guard eventNow.isFinite,eventNow>=lastProcessingTime else {
                return retireClockFault(result,session:&session,send:send)
            }
            lastProcessingTime=eventNow
            let now=eventNow
            switch event {
            case .ready: ready = true
            case .disconnected,.fault: break
            case .invitation(let id,let secret,let receipt):
                guard ready,!rejected.contains(id),bindings[id] == nil,
                      fresh(receipt,now:now),
                      let issued = invitationIssuedAt,receipt >= issued,
                      let source = try? pairing.consume(secret:secret,now:now) else {
                    result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
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
                      !binding.metadataExpired(now:now),
                      fresh(receipt,now:now),let validated = try? ValidatedGroupRemoteFrame(bytes:bytes) else {
                    result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
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
                    result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                let received = session.receiveRemoteValidated(binding.source,token:binding.token,validated:validated,
                                                              hostTime:receipt,now:now,refreshNow:trackedClock,send:send)
                result.reports += received.reports
                guard received.status == .ready || received.status == .waitingForNeutral || received.status == .delivered else {
                    result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                // The session may have synchronously released another
                // source. An incomplete negotiation cannot cross its
                // absolute budget during that work and then start play
                // or disclose a label page as if still timely.
                let completedAt=trackedClock?() ?? now
                guard completedAt.isFinite,completedAt>=now else {
                    return retireClockFault(result,session:&session,send:send)
                }
                lastProcessingTime=completedAt
                guard !binding.metadataExpired(now:completedAt) else {
                    result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
                    rejected.insert(id)
                    result.actions.append(.acknowledge(id,false))
                    continue
                }
                switch frame.kind {
                case .capabilities:
                    guard let capabilities = session.remoteCapabilities(binding.source) else {
                        result.reports += remove([id],session:&session,refreshNow:trackedClock,send:send)
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
                    if binding.labelsComplete {
                        // The consented snapshot is no longer needed once
                        // the final response has been built. No refresh.
                        binding.labels.removeAll()
                        binding.metadataStartedAt=nil
                    }
                    result.actions.append(.mappingLabels(id,response))
                case .heartbeat:
                    result.actions.append(.acknowledge(id,true))
                default:
                    binding.performanceStarted = true
                    // Optional labels omitted by a performing client must
                    // never be retained for a later metadata refresh.
                    binding.labels.removeAll()
                    binding.metadataStartedAt=nil
                    result.actions.append(.acknowledge(id,true))
                }
                bindings[id] = binding
            }
        }
        // The batch can cross a metadata deadline even with no frame from
        // that peer (or no events at all). Drain newly expired negotiations
        // in bounded rounds, with the original ten-second deadline.
        for _ in 0...(bindings.count + session.boundSources.count) {
            let current=trackedClock?() ?? now
            guard current.isFinite,current>=lastProcessingTime else {
                return retireClockFault(result,session:&session,send:send)
            }
            lastProcessingTime=current
            let timedOut=Set(bindings.compactMap { id,binding in
                binding.metadataExpired(now:current) ? id : nil
            })
            var departures:[SensorSource:UUID] = [:]
            for id in timedOut {
                if let binding = bindings.removeValue(forKey:id) { departures[binding.source] = binding.token }
            }
            // The final clock observation must govern physical and remote
            // leases too, not only the ten-second metadata negotiation.
            // Batch known departures with all expired leases before restoring.
            let drained = session.expire(now:current,removingRemote:departures,
                                         refreshNow:trackedClock,send:send)
            result.reports += drained
            result.actions += timedOut.sorted(by:{ $0.uuidString < $1.uuidString }).map { .revoke($0) }
            result.actions += reconcileRevoked(session:session)
            // A slow final note-off can itself cross a metadata deadline.
            // Repeat only after a departure or actual scoped cleanup.
            guard !timedOut.isEmpty || !drained.isEmpty else { break }
        }
        guard !clockFault else { return retireClockFault(result,session:&session,send:send) }
        // Another peer's cleanup can expire an authenticated slot.
        result.actions += reconcileRevoked(session:session)
        discardInvalidMetadata(in:&result)
        return result
    }

    /// A broken trusted host clock invalidates all Group leases, not
    /// only the peers owned by this bridge. Reset them atomically without
    /// consulting another sample from the already invalid clock.
    private mutating func retireClockFault(_ previous:PerformanceGroupRemoteBatch,
                                            session:inout PerformanceGroupGamepadSession,
                                            send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupRemoteBatch {
        var result = previous
        result.reports += session.expire(now:.nan,send:send)
        let retirement = stop(session:&session,send:send)
        result.reports += retirement.reports
        result.actions += retirement.actions
        result.fault = true
        discardInvalidMetadata(in:&result)
        return result
    }

    /// Actions are applied only after process returns. Never publish queued
    /// success or metadata for a connection retired later in the same batch.
    private func discardInvalidMetadata(in result:inout PerformanceGroupRemoteBatch) {
        result.actions.removeAll { action in
            switch action {
            case .acknowledge(let id,true),.capabilities(let id,_),.mapping(let id,_),.mappingLabels(let id,_):
                return bindings[id] == nil
            default: return false
            }
        }
    }

    private mutating func reconcileRevoked(session:PerformanceGroupGamepadSession) -> [RemoteHostAction] {
        let expired=bindings.compactMap { id,binding in
            session.matchesRemoteBinding(binding.source,token:binding.token) ? nil : id
        }.sorted(by:{ $0.uuidString < $1.uuidString })
        for id in expired { bindings.removeValue(forKey:id) }
        return expired.map { .revoke($0) }
    }

    private mutating func remove(_ ids:Set<UUID>,session:inout PerformanceGroupGamepadSession,refreshNow:(()->Double)? = nil,
                                 send:(PerformanceGroupCommand)->Bool) -> [PerformanceGroupDelivery.Report] {
        var tokens:[SensorSource:UUID] = [:]
        for id in ids {
            if let binding = bindings.removeValue(forKey:id) { tokens[binding.source] = binding.token }
        }
        return session.unbindRemoteBatch(tokens,refreshNow:refreshNow,send:send)
    }

    private func fresh(_ receipt:Double,now:Double) -> Bool {
        MonotonicReceiptAdmission.permits(receipt:receipt,now:now,maximumAge:0.1)
    }
}
