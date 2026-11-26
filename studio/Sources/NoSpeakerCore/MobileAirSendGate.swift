import Foundation

/// Socket-independent single lane. Transport must complete group negotiation,
/// transfer exclusive sequence ownership, synchronously dispatch sends, route
/// ACKs only from the current connection and independently poll/close.
/// Time is nonnegative monotonic nanoseconds, never remote wall time.
public struct MobileAirSendGate: Sendable {
    public enum Action: Equatable, Sendable {
        case wait, send(Data), close(String)
    }
    public static let maximumSequence: UInt64 = 9_007_199_254_740_991
    public static let ackNS: Int64 = 220_000_000
    public static let freshNS: Int64 = 150_000_000
    public static let paceNS: Int64 = 13_000_000
    public static let refreshNS: Int64 = 50_000_000
    public static let idleNS: Int64 = 1_000_000_000
    private let lane: MobileAirWireLane
    private var sequence: UInt64
    private var started = false
    private var admitted = false
    private var closed = false
    private var clock: Int64?
    private var lastSend: Int64?
    private var pendingAt: Int64?
    private var pendingNeutral = false
    private var sent = MobileAirOutput()
    private var sample: MobileAirOutput?
    private var sampledAt: Int64?
    private var lastInput: Int64?
    private var releaseDebtAt: Int64?
    private var neutralFence = false
    private var neutralConfirmedAt: Int64?
    public init?(lane: MobileAirWireLane, initialSequence: UInt64) {
        guard initialSequence < Self.maximumSequence,
              (try? lane.encode(.init(),sequence:1)) != nil else {return nil}
        self.lane=lane; sequence=initialSequence
    }
    private mutating func close(_ reason:String) -> Action {
        closed=true;admitted=false;pendingAt=nil;sample=nil;releaseDebtAt=nil
        return .close(reason)
    }
    private mutating func check(_ now:Int64) -> Action? {
        if closed {return .close("Already closed")}
        guard now>=0,clock.map({now >= $0}) ?? true else {return close("Invalid monotonic clock")}
        clock=now
        if let pendingAt,now-pendingAt>=Self.ackNS {return close("ACK timeout")}
        if let releaseDebtAt,now-releaseDebtAt>=Self.freshNS {return close("Release overdue")}
        return nil
    }
    private mutating func send(_ value:MobileAirOutput,now:Int64,heartbeat:Bool=false) -> Action {
        guard sequence<Self.maximumSequence else {return close("Sequence exhausted")}
        let next=sequence+1
        let bytes:Data
        do {
            if heartbeat {
                bytes=Data("{\"kind\":\"heartbeat\",\"version\":1,\"sequence\":\(next)}".utf8)
            } else {bytes=try lane.encode(value,sequence:next)}
        } catch {return close("Invalid logical snapshot")}
        sequence=next;pendingAt=now;lastSend=now
        pendingNeutral = !heartbeat && value == .init()
        if !heartbeat {sent=value}
        return .send(bytes)
    }
    public mutating func begin(now:Int64)->Action {
        if let failure=check(now){return failure}
        guard !started else {return close("Duplicate start")}
        started=true;return send(.init(),now:now)
    }
    public mutating func acknowledge(_ response:String,now:Int64)->Action {
        if let failure=check(now){return failure}
        guard started,pendingAt != nil,response=="accepted" else {return close("Unexpected ACK")}
        // A late active ACK must not erase a source expiry that occurred while pending.
        if sourceExpired(now),sent != .init(),!pendingNeutral {return close("Source expired while active ACK outstanding")}
        pendingAt=nil
        if pendingNeutral {
            admitted=true;neutralFence=false;releaseDebtAt=nil;neutralConfirmedAt=now
            sample=nil;sampledAt=nil
        }
        pendingNeutral=false
        return poll(now:now)
    }
    private func sourceExpired(_ now:Int64)->Bool {
        sampledAt.map {now-$0>=Self.freshNS} ?? false
    }
    private mutating func expireSample(_ now:Int64) {
        guard let at=sampledAt,now-at>=Self.freshNS else {return}
        sample=nil;sampledAt=nil
        if sent != .init(),!neutralFence {neutralFence=true;releaseDebtAt=at+Self.freshNS}
    }
    public mutating func offer(_ output:MobileAirOutput,observedAt:Int64,now:Int64)->Action {
        if let failure=check(now){return failure}
        guard started else {return close("Not started")}
        guard observedAt>=0,observedAt<=now,now-observedAt<Self.freshNS,
              lastInput.map({observedAt>$0}) ?? true else {return close("Stale or replayed observation")}
        lastInput=observedAt
        guard (try? lane.encode(output,sequence:1)) != nil else {return close("Invalid logical snapshot")}
        guard admitted else {return .wait}
        if sourceExpired(now),sent != .init(),pendingAt != nil {return close("Source expired while active ACK outstanding")}
        expireSample(now)
        if neutralFence || !(neutralConfirmedAt.map {observedAt>$0} ?? false) {return poll(now:now)}
        if output == .init() {
            sample=nil;sampledAt=nil
            if sent != .init() {neutralFence=true;releaseDebtAt=observedAt}
            return poll(now:now)
        }
        if let previous=sample,previous.keys != output.keys,previous.keys != 0,output.keys != 0,
           pendingAt != nil || (lastSend.map {now-$0<Self.paceNS} ?? false) {
            return close("Discrete edge cannot be delivered on time")
        }
        sample=output;sampledAt=observedAt
        return poll(now:now)
    }
    public mutating func poll(now:Int64)->Action {
        if let failure=check(now){return failure}
        guard started,admitted else {return .wait}
        let expiredActive=sourceExpired(now) && sent != .init()
        expireSample(now)
        if let failure=check(now){return failure}
        if expiredActive,pendingAt != nil {return close("Source expired while active ACK outstanding")}
        guard pendingAt == nil else {return .wait}
        let elapsed=lastSend.map {now-$0} ?? Int64.max
        guard elapsed>=Self.paceNS else {return .wait}
        if neutralFence {return send(.init(),now:now)}
        if let sample,sample != sent || elapsed>=Self.refreshNS {return send(sample,now:now)}
        if sent == .init(),elapsed>=Self.idleNS {return send(.init(),now:now,heartbeat:true)}
        return .wait
    }
    public mutating func abort()->Action {close("Stopped explicitly")}
}
