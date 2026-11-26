import Foundation

/// A separate UI ownership/liveness contract, NOT a camera acquisition.
/// The caller runs on the current native view owner and must independently
/// prove foreground, focus, visibility and current contact ownership on
/// each event/pulse. A stationary finger need not generate a move event.
/// A missed owner pulse is terminal, including while neutral. The transport
/// must still independently expire/close and reject stale generations.
/// No socket integration or physical device acceptance is implied.
public struct MobileTouchLiveLease:Sendable {
    public struct Snapshot:Equatable,Sendable {
        public let output:MobileAirOutput
        public let ownerAt:Int64
    }
    private var ownership:MobileTouchOwnership
    private var last:Int64
    public var retired:Bool{ownership.retired}
    public var output:MobileAirOutput{ownership.output}
    public init?(authorized:Int,armedAt:Int64){
        guard armedAt>=0,let owner=MobileTouchOwnership(authorized:authorized) else{return nil}
        ownership=owner;last=armedAt
    }
    public mutating func retire(){ownership.retire()}
    private mutating func check(now:Int64,ownerActive:Bool)->Bool {
        guard !retired,ownerActive,now>last,now-last<MobileAirSendGate.freshNS else{
            retire();return false
        }
        last=now;return true
    }
    public mutating func event(_ change:MobileTouchOwnership.Change,
                               contacts:[MobileTouchKeys.Contact],now:Int64,ownerActive:Bool)->Snapshot? {
        guard check(now:now,ownerActive:ownerActive),
              let value=ownership.update(change,contacts:contacts) else{return nil}
        return .init(output:value,ownerAt:now)
    }
    /// Called only by the live view owner, never a network watchdog or
    /// background task. No replay of prior event timestamps.
    public mutating func pulse(now:Int64,ownerActive:Bool)->Snapshot? {
        guard check(now:now,ownerActive:ownerActive) else{return nil}
        return .init(output:ownership.output,ownerAt:now)
    }
}
