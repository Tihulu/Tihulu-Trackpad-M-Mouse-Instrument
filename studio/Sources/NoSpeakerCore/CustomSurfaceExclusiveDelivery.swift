import Foundation

/// Synchronous injected-sink delivery for an exclusively reserved endpoint.
/// Not an endpoint reservation or physical adapter: the caller must prove
/// exclusivity, serialize calls and bind the sink to the same endpoint until
/// debt is cleared. Never attach this independent ledger to a shared port.
public final class CustomSurfaceExclusiveDelivery {
    public enum Retirement:Equatable,Sendable {case expiredOrInvalid,admissionDenied,sendFailed,stopped}
    public struct Report:Equatable,Sendable {
        public let accepted:Int
        public let retirement:Retirement?
        public let outstanding:Set<SensorDestination>
        public var retired:Bool {retirement != nil}
        public var pendingCleanup:Set<SensorDestination> {retired ? outstanding:[]}
    }
    private let plan:CustomSurfaceMixedPlan
    private var projection:CustomSurfaceContactProjection
    private var ledger=PatchOutputLedger()
    private var notes:Set<SensorDestination>=[]
    private var sustain:Set<Int>=[]
    private var controls:[SensorDestination:LegacyContinuousOwners.Value]=[:]
    private let clock:()->Int64
    private let admits:()->Bool
    private let send:(SensorCommand)->Bool
    private var lastClock:Int64?
    public private(set) var retirement:Retirement?

    public init(plan:CustomSurfaceMixedPlan,clock:@escaping ()->Int64,
                admitsExclusiveEndpoint:@escaping ()->Bool,send:@escaping (SensorCommand)->Bool) {
        self.plan=plan;projection = .init(layout:plan.layout)
        self.clock=clock;admits=admitsExclusiveEndpoint;self.send=send
    }

    private func tick()->Int64? {
        let now=clock()
        guard now>=0,lastClock.map({now >= $0}) ?? true else{return nil}
        lastClock=now
        return now
    }
    private func liveFailure(observedAt:Int64)->Retirement? {
        guard admits() else{return .admissionDenied}
        guard let now=tick(),observedAt>=0,now>=observedAt,
              now-observedAt<MobileAirSendGate.freshNS else{return .expiredOrInvalid}
        return nil
    }
    private func report(_ count:Int)->Report {
        .init(accepted:count,retirement:retirement,outstanding:ledger.outstanding)
    }
    private func clean()->Int {
        var count=0
        _=ledger.releaseAll { command in
            let ok=send(command)
            if ok {count+=1}
            return ok
        }
        return count
    }
    private func retire(_ reason:Retirement,accepted:Int=0)->Report {
        guard retirement==nil else{return report(accepted)}
        retirement=reason
        _=projection.retire()
        notes=[];sustain=[];controls=[:]
        return report(accepted+clean())
    }
    private static func sorted(_ targets:Set<SensorDestination>)->[SensorDestination] {
        targets.sorted {
            if $0.channel != $1.channel {return $0.channel<$1.channel}
            if $0.kind != $1.kind {return $0.kind.rawValue<$1.kind.rawValue}
            return $0.number<$1.number
        }
    }

    public func frame(_ contacts:[CustomSurfaceContactProjection.Contact],
                      sequence:UInt64,observedAt:Int64)->Report {
        guard retirement==nil else{return report(0)}
        if let reason=liveFailure(observedAt:observedAt){return retire(reason)}
        guard let now=lastClock else{return retire(.expiredOrInvalid)}
        let snapshot=projection.frame(contacts,sequence:sequence,observedAt:observedAt,now:now)
        guard !snapshot.retired,let output=plan.output(for:snapshot) else{return retire(.expiredOrInvalid)}
        // Keep one gate for each shared note; the first stable contact
        // determines velocity only on a genuinely new onset.
        var desired:[SensorDestination:Int]=[:]
        for contact in output.notes.desired.keys.sorted() {
            for target in output.notes.desired[contact] ?? [] where desired[target]==nil {
                desired[target]=output.notes.velocities[contact] ?? 1
            }
        }
        let nextNotes=Set(desired.keys)
        let nextSustain=output.sustainChannels
        let nextControls=output.continuous
        var commands:[SensorCommand]=[]
        for ch in nextSustain.subtracting(sustain).sorted() {
            commands.append(.init(.init(.sustain,channel:ch),value:127))
        }
        for target in Self.sorted(Set(nextControls.keys)) {
            guard let next=nextControls[target],controls[target] != next else{continue}
            commands.append(.init(target,value:next.value))
        }
        for target in Self.sorted(nextNotes.subtracting(notes)) {
            commands.append(.init(target,value:desired[target] ?? 1))
        }
        for target in Self.sorted(notes.subtracting(nextNotes)) {
            commands.append(.init(target,value:0))
        }
        for ch in sustain.subtracting(nextSustain).sorted() {
            commands.append(.init(.init(.sustain,channel:ch),value:0))
        }
        for target in Self.sorted(Set(controls.keys).subtracting(nextControls.keys)) {
            guard let old=controls[target] else{continue}
            commands.append(.init(target,value:old.neutral))
        }
        var count=0
        for command in commands {
            if let reason=liveFailure(observedAt:observedAt){return retire(reason,accepted:count)}
            guard ledger.deliver(command,send:send) else{return retire(.sendFailed,accepted:count)}
            count+=1
        }
        // Also fence silent ownership joins and synchronous sink latency.
        if let reason=liveFailure(observedAt:observedAt){return retire(reason,accepted:count)}
        notes=nextNotes;sustain=nextSustain;controls=nextControls
        return report(count)
    }
    public func poll()->Report {
        guard retirement==nil else{return report(0)}
        guard admits() else{return retire(.admissionDenied)}
        guard let now=tick(),!projection.poll(now:now).retired else{return retire(.expiredOrInvalid)}
        return report(0)
    }
    public func stop()->Report {retire(.stopped)}
    /// Never retry active output; retirement does not clear failed debt.
    public func retryCleanup()->Report {
        guard retirement != nil else{return report(0)}
        return report(clean())
    }
}
