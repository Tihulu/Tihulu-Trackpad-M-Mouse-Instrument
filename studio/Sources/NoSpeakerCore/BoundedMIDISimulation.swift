import Foundation

/// Offline execution of the exact bounded note schedule against an
/// independent in-memory receiver. No clock sleep, native endpoints,
/// permissions, MIDI output or DAW interaction.
public enum BoundedMIDISimulation {
    public enum Failure:LocalizedError {
        case invalidSchedule
        public var errorDescription:String? { "MIDI simulation did not complete cleanly." }
    }
    public struct Report:Encodable,Equatable,Sendable {
        public let noteOns:Int
        public let noteOffs:Int
        public let peakConcurrentNotes:Int
        public let durationNS:UInt64
        public let outstandingNotes:Int
        public let completed:Bool
        public let hardware:Bool
        public let receiverConfirmed:Bool
    }

    public struct Audit:Encodable,Equatable,Sendable {
        public let eventCount:Int
        public let scenarios:Int
        public let passedScenarios:Int
        public let maximumCleanupDebt:Int
        public let allCleanAfterRetry:Bool
        public let hardware:Bool
        public let receiverConfirmed:Bool
    }

    /// Sweep every planned send edge twice: delivery failed before or
    /// after reaching the simulated receiver. All immediate cleanup sends
    /// then fail, followed by a partial retry and a successful owned-debt retry.
    /// Work is bounded by the same 256-note/512-event schedule limit.
    public static func audit(_ schedule:BoundedMIDIPlayback,
                             shouldStop:()->Bool = { false }) throws -> Audit {
        guard schedule.state == .ready,!schedule.events.isEmpty else { throw Failure.invalidSchedule }
        var passed=0,maximumDebt=0
        for edge in schedule.events.indices {
            for delivered in [false,true] {
                if shouldStop() { throw CancellationError() }
                var player=schedule
                guard try player.begin(now:0) else { throw Failure.invalidSchedule }
                var sounding:Set<SensorDestination>=[]
                // Independent expected debt tracks successful releases,
                // not merely every note ever admitted during this clip.
                var expectedDebt:Set<SensorDestination>=[]
                var failed=false,valid=true,attempted=0,steps=0
                var cleanup:Set<SensorDestination>=[]
                func receive(_ command:SensorCommand) {
                    if command.value>0 {
                        if !sounding.insert(command.destination).inserted { valid=false }
                    } else if sounding.remove(command.destination)==nil {
                        valid=false
                    }
                }
                while let deadline=player.nextDeadline {
                    if shouldStop() { throw CancellationError() }
                    guard steps<=schedule.events.count else { throw Failure.invalidSchedule }
                    steps+=1
                    player.advance(now:deadline) { command in
                        if failed {
                            // No new note or unrelated cleanup is permitted.
                            if command.value != 0 || !expectedDebt.contains(command.destination) ||
                                !cleanup.insert(command.destination).inserted { valid=false }
                            return false
                        }
                        guard attempted<schedule.events.count,
                              command==schedule.events[attempted].command else {
                            valid=false;failed=true;return false
                        }
                        if command.value>0 { expectedDebt.insert(command.destination) }
                        let failNow=attempted==edge
                        attempted+=1
                        if failNow {
                            failed=true
                            if delivered { receive(command) }
                            return false
                        }
                        receive(command)
                        if command.value==0 { expectedDebt.remove(command.destination) }
                        return true
                    }
                }
                let debt=player.outstanding
                guard valid,failed,attempted==edge+1,player.state == .faulted,
                      player.fault == .sendFailed,cleanup==debt,
                      sounding.isSubset(of:debt),debt==expectedDebt else {
                    throw Failure.invalidSchedule
                }
                maximumDebt=max(maximumDebt,debt.count)
                // Exercise a partial retry as well. Only unresolved
                // destinations may appear in the second retry.
                var retries:Set<SensorDestination>=[]
                var remaining:Set<SensorDestination>=[]
                player.retryCleanup { command in
                    if command.value != 0 || !debt.contains(command.destination) ||
                        !retries.insert(command.destination).inserted { valid=false }
                    if retries.count % 2 == 1 {
                        remaining.insert(command.destination)
                        // Failed delivery is deliberately ambiguous.
                        if delivered { sounding.remove(command.destination) }
                        return false
                    }
                    sounding.remove(command.destination)
                    return true
                }
                guard valid,retries==debt,player.outstanding==remaining,
                      sounding.isSubset(of:remaining),player.state == .faulted else {
                    throw Failure.invalidSchedule
                }
                retries.removeAll()
                player.retryCleanup { command in
                    if command.value != 0 || !remaining.contains(command.destination) ||
                        !retries.insert(command.destination).inserted { valid=false }
                    // Duplicate note-off is intentional for ambiguous
                    // delivery, but only for an owned unresolved debt.
                    sounding.remove(command.destination)
                    return true
                }
                guard valid,retries==remaining,sounding.isEmpty,player.outstanding.isEmpty,
                      player.state == .faulted,player.fault == .sendFailed else {
                    throw Failure.invalidSchedule
                }
                passed+=1
            }
        }
        if shouldStop() { throw CancellationError() }
        return .init(eventCount:schedule.events.count,scenarios:schedule.events.count*2,
            passedScenarios:passed,maximumCleanupDebt:maximumDebt,allCleanAfterRetry:true,
            hardware:false,receiverConfirmed:false)
    }

    /// Accept only a fresh prepared schedule. The simulated receiver
    /// independently rejects duplicate ons and offs without ownership.
    public static func run(_ schedule:BoundedMIDIPlayback) throws -> Report {
        var player=schedule
        guard try player.begin(now:0) else { throw Failure.invalidSchedule }
        var sounding:Set<SensorDestination>=[]
        var on=0,off=0,peak=0,valid=true
        var steps=0
        while let deadline=player.nextDeadline {
            // At most one advance per event plus trailing silence.
            guard steps<=player.events.count else { throw Failure.invalidSchedule }
            steps+=1
            player.advance(now:deadline) { command in
                if command.value>0 {
                    guard sounding.insert(command.destination).inserted else { valid=false;return false }
                    on+=1
                    peak=max(peak,sounding.count)
                } else {
                    guard sounding.remove(command.destination) != nil else { valid=false;return false }
                    off+=1
                }
                return true
            }
        }
        guard valid,player.state == .finished,sounding.isEmpty,player.outstanding.isEmpty,
              on==off,on+off==player.events.count else { throw Failure.invalidSchedule }
        return .init(noteOns:on,noteOffs:off,peakConcurrentNotes:peak,durationNS:player.durationNS,
                     outstandingNotes:0,completed:true,hardware:false,receiverConfirmed:false)
    }
}
