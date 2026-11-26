import Foundation

/// One transport write at a time. An ACK racing the local send completion
/// cannot advance the protocol until the exact write succeeds. No retries,
/// unbounded receive buffering, or deadline extension from early replies.
/// Call only on the owning serialized transport queue.
public struct MobileLANWriteFence: Sendable {
    public static let writeNS:Int64 = 50_000_000
    public enum Result:Equatable, Sendable {
        case wait, deliver(String), close(String)
    }
    private var active:UInt64?
    private var sequence:UInt64=0
    private var beganAt:Int64?
    private var lastClock:Int64?
    private var deferred:String?
    private var retired=false
    public init(){}
    public var isWriting:Bool { active != nil }
    private mutating func fail(_ reason:String)->Result {
        retire()
        return .close(reason)
    }
    private mutating func check(_ now:Int64)->Result? {
        if retired{return .close("Write fence retired")}
        guard now>=0,lastClock.map({now >= $0}) ?? true else {
            return fail("Invalid transport clock")
        }
        lastClock=now
        if let beganAt,now-beganAt>=Self.writeNS{return fail("Transport write timed out")}
        return nil
    }
    /// nil means the caller must close, not enqueue or retry.
    public mutating func begin(now:Int64)->UInt64? {
        if check(now) != nil{return nil}
        guard active==nil,sequence<UInt64.max else {retire();return nil}
        sequence+=1;active=sequence;beganAt=now
        return sequence
    }
    public mutating func receive(_ reply:String,now:Int64)->Result {
        if let failure=check(now){return failure}
        guard reply.utf8.count<=RemoteTouchFrame.maximumBytes,
              reply.utf8.allSatisfy({$0<128}) else {return fail("Invalid transport reply")}
        if active==nil{return .deliver(reply)}
        guard deferred==nil else{return fail("Duplicate early reply")}
        deferred=reply
        return .wait
    }
    public mutating func complete(_ lease:UInt64,success:Bool,now:Int64)->Result {
        if let failure=check(now){return failure}
        guard active==lease,success else{return fail("Invalid or failed transport write")}
        active=nil;beganAt=nil
        let reply=deferred;deferred=nil
        return reply.map{.deliver($0)} ?? .wait
    }
    public mutating func poll(now:Int64)->Result {
        check(now) ?? .wait
    }
    public mutating func retire(){
        retired=true;active=nil;beganAt=nil;deferred=nil
    }
}
