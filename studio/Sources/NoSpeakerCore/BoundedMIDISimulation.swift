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
