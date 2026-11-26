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
    private var stringDeadlines: [Int: Int64] = [:]
    private var lastInput: Int64?
    private var releaseDebtAt: Int64?
    private var neutralFence = false
    private var neutralConfirmedAt: Int64?
    private var releaseSourceAt: Int64?
    private var releaseStringDeadline: Int64?
    public init?(lane: MobileAirWireLane, initialSequence: UInt64) {
        guard initialSequence < Self.maximumSequence,
              (try? lane.encode(.init(),sequence:1)) != nil else {return nil}
        self.lane=lane; sequence=initialSequence
    }
    private mutating func close(_ reason:String) -> Action {
        closed=true;admitted=false;pendingAt=nil;sample=nil;stringDeadlines=[:];releaseDebtAt=nil;releaseSourceAt=nil;releaseStringDeadline=nil
        return .close(reason)
    }
    private mutating func check(_ now:Int64) -> Action? {
        if closed {return .close("Already closed")}
        guard now>=0,clock.map({now >= $0}) ?? true else {return close("Invalid monotonic clock")}
        clock=now
        if let pendingAt,now-pendingAt>=Self.ackNS {return close("ACK timeout")}
        if let releaseDebtAt,now-releaseDebtAt>=Self.freshNS {return close("Release overdue")}
        if sent != .init(),pendingAt != nil,!pendingNeutral,
           let at=releaseSourceAt,now-at>=Self.freshNS {
            return close("Source expired while active ACK outstanding")
        }
        if sent.keys != 0,let deadline=releaseStringDeadline,now>=deadline,
           pendingAt != nil || lastSend.map({now-$0<Self.paceNS}) == true {
            return close("String release deadline blocked")
        }
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
        if expireStrings(now), !pendingNeutral {return close("String expired while active ACK outstanding")}
        pendingAt=nil
        if pendingNeutral {
            admitted=true;neutralFence=false;releaseDebtAt=nil;neutralConfirmedAt=now
            releaseSourceAt=nil;releaseStringDeadline=nil
            sample=nil;sampledAt=nil;stringDeadlines=[:]
        }
        pendingNeutral=false
        return poll(now:now)
    }
    private func sourceExpired(_ now:Int64)->Bool {
        sampledAt.map {now-$0>=Self.freshNS} ?? false
    }
    private mutating func expireSample(_ now:Int64) {
        guard let at=sampledAt,now-at>=Self.freshNS else {return}
        sample=nil;sampledAt=nil;stringDeadlines=[:]
        if sent != .init(),!neutralFence {neutralFence=true;releaseDebtAt=at+Self.freshNS}
    }
    private mutating func expireStrings(_ now: Int64) -> Bool {
        guard var value = sample, !stringDeadlines.isEmpty else { return false }
        let expired = stringDeadlines.filter { $0.value <= now }
        guard let firstExpiry = expired.values.min() else { return false }
        var mask = 0
        for key in expired.keys {
            mask |= 1 << key
            value.keys &= ~(1 << key)
            stringDeadlines.removeValue(forKey: key)
        }
        if value.keys != 0 {
            sample = value
        } else {
            sample = nil
            if sent.keys != 0 && !neutralFence {
                neutralFence = true
                releaseDebtAt = firstExpiry
            }
        }
        return sent.keys & mask != 0
    }

    public mutating func offer(_ output:MobileAirOutput,observedAt:Int64,now:Int64,
                               stringDeadlines: [Int: Int64] = [:])->Action {
        if let failure=check(now){return failure}
        guard started else {return close("Not started")}
        guard observedAt>=0,observedAt<=now,now-observedAt<Self.freshNS,
              lastInput.map({observedAt>$0}) ?? true else {return close("Stale or replayed observation")}
        lastInput=observedAt
        guard (try? lane.encode(output,sequence:1)) != nil else {return close("Invalid logical snapshot")}
        if !stringDeadlines.isEmpty {
            guard output.level == nil,
                  stringDeadlines.allSatisfy({ key, deadline in
                      (0..<25).contains(key) && deadline > observedAt && deadline-observedAt <= 120_000_000
                  }),
                  stringDeadlines.keys.reduce(0, { $0 | (1 << $1) }) == output.keys
            else { return close("Invalid string expiry") }
        }
        guard admitted else {return .wait}
        if sourceExpired(now),sent != .init(),pendingAt != nil {return close("Source expired while active ACK outstanding")}
        if expireStrings(now) {
            if pendingAt != nil {return close("String expired while active ACK outstanding")}
            if lastSend.map({now-$0<Self.paceNS}) == true {return close("String release blocked by send pacing")}
            return poll(now:now)
        }
        expireSample(now)
        if neutralFence || !(neutralConfirmedAt.map {observedAt>$0} ?? false) {return poll(now:now)}
        if output == .init() {
            rememberReleaseDeadlines()
            sample=nil;sampledAt=nil;self.stringDeadlines=[:]
            if sent != .init() {neutralFence=true;releaseDebtAt=observedAt}
            return poll(now:now)
        }
        if let previous=sample,previous.keys != output.keys,previous.keys != 0,output.keys != 0,
           pendingAt != nil || (lastSend.map {now-$0<Self.paceNS} ?? false) {
            return close("Discrete edge cannot be delivered on time")
        }
        self.stringDeadlines = stringDeadlines
        sample=output;sampledAt=observedAt
        return poll(now:now)
    }
    private mutating func rememberReleaseDeadlines() {
        guard sent != .init() else {return}
        if let at=sampledAt {releaseSourceAt=min(releaseSourceAt ?? at,at)}
        let mask=sent.keys
        if let deadline=stringDeadlines.filter({mask & (1 << $0.key) != 0}).values.min() {
            releaseStringDeadline=min(releaseStringDeadline ?? deadline,deadline)
        }
    }
    public mutating func poll(now:Int64)->Action {
        if let failure=check(now){return failure}
        guard started,admitted else {return .wait}
        let expiredActive=sourceExpired(now) && sent != .init()
        if expireStrings(now) {
            if pendingAt != nil {return close("String expired while active ACK outstanding")}
            if lastSend.map({now-$0<Self.paceNS}) == true {return close("String release blocked by send pacing")}
        }
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
    var neutralReady:Bool {
        started && admitted && !closed && pendingAt == nil && !neutralFence && sent == .init() && sample == nil
    }
    mutating func requestNeutral(now:Int64)->Action {
        if let failure=check(now){return failure}
        guard started,admitted else {return close("Neutral transition before admission")}
        if sourceExpired(now),sent != .init(),pendingAt != nil,!pendingNeutral {
            return close("Source expired while active ACK outstanding")
        }
        let mask=sent.keys
        let activeStrings=stringDeadlines.keys.contains {mask & (1 << $0) != 0}
        if activeStrings,!pendingNeutral,pendingAt != nil || lastSend.map({now-$0<Self.paceNS}) == true {
            return close("Mode change cannot delay string release")
        }
        let debt=min(releaseDebtAt ?? now,now)
        let origin=sampledAt.flatMap {now-$0>=Self.freshNS ? $0+Self.freshNS : nil}
        rememberReleaseDeadlines()
        sample=nil;sampledAt=nil;stringDeadlines=[:]
        neutralFence=true;releaseDebtAt=min(debt,origin ?? now)
        return poll(now:now)
    }
    public mutating func abort()->Action {close("Stopped explicitly")}
}
