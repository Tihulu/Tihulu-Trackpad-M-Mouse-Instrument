import Foundation

/// Single-use native protocol state machine. A transport adapter must
/// independently authenticate TLS/hostname, validate the negotiated subprotocol,
/// serialize all calls, dispatch actions immediately and poll on its own clock.
/// This type cannot open sockets, verify certificates or grant host authority.
public struct MobileLANSession: Sendable {
    public enum Selection: Sendable { case keys, helper(Int) }
    public enum Phase: Equatable, Sendable { case idle, admission, capabilities, neutralDelay, neutralACK, ready, closed }
    public enum Action: Equatable, Sendable { case wait, binary(Data), text(Data), close(String) }
    public private(set) var phase:Phase = .idle
    private let selection:Selection
    private var clock:Int64?
    private var pendingAt:Int64?
    private var capabilitiesSentAt:Int64?
    private var gate:MobileAirSendGate?
    private var lane:MobileAirWireLane?
    private var manifest: MobileLANCapabilities.Manifest?

    /// A camera can adopt this assignment only after the host has confirmed neutral.
    public var readyManifest: MobileLANCapabilities.Manifest? {
        phase == .ready ? manifest : nil
    }
    public init(selection:Selection){self.selection=selection}
    private mutating func close(_ reason:String)->Action {
        phase = .closed;gate=nil;lane=nil;manifest=nil;pendingAt=nil
        return .close(reason)
    }
    private mutating func check(_ now:Int64)->Action? {
        guard phase != .closed else {return .close("Already closed")}
        guard now>=0,clock.map({now >= $0}) ?? true else {return close("Invalid monotonic clock")}
        clock=now
        if let pendingAt {
            let limit:Int64 = phase == .admission ? 3_000_000_000 : MobileAirSendGate.ackNS
            if now-pendingAt>=limit{return close("Negotiation timeout")}
        }
        return nil
    }
    /// Call only for the current socket after platform trust succeeds.
    /// Never put the invitation in URL, logs or persistent storage.
    public mutating func begin(trustedTLS:Bool,subprotocol negotiated:String,invitation:String,now:Int64)->Action {
        if let failure=check(now){return failure}
        guard phase == .idle,trustedTLS,negotiated==RemoteHandshakePolicy.subprotocol,
              let bytes=MobileLANEndpoint.invitationBytes(invitation) else {return close("Untrusted or invalid connection")}
        phase = .admission;pendingAt=now
        return .binary(bytes)
    }
    private mutating func translate(_ action:MobileAirSendGate.Action)->Action {
        switch action {
        case .wait:return .wait
        case .send(let data):return .text(data)
        case .close(let reason):return close(reason)
        }
    }
    public mutating func receive(text:String,now:Int64)->Action {
        if let failure=check(now){return failure}
        guard text.utf8.count<=RemoteTouchFrame.maximumBytes else {return close("Oversized response")}
        switch phase {
        case .admission:
            guard text=="admitted" else {return close("Admission refused")}
            phase = .capabilities;pendingAt=now;capabilitiesSentAt=now
            return .text(Data(#"{"kind":"capabilities","version":7,"sequence":1}"#.utf8))
        case .capabilities:
            guard let manifest=MobileLANCapabilities.parseSingleFamily(Data(text.utf8)) else {return close("Unsupported manifest")}
            switch selection {
            case .keys:lane=manifest.keysLane()
            case .helper(let index):lane=manifest.helperLane(index:index)
            }
            guard lane != nil else {return close("Unassigned lane")}
            self.manifest = manifest
            pendingAt=nil;phase = .neutralDelay
            return poll(now:now)
        case .neutralACK,.ready:
            guard var sender=gate else {return close("Missing sender")}
            let initial=phase == .neutralACK
            let result=sender.acknowledge(text,now:now)
            gate=sender
            if initial,case .wait=result {phase = .ready}
            return translate(result)
        default:return close("Unexpected response")
        }
    }
    public mutating func poll(now:Int64)->Action {
        if let failure=check(now){return failure}
        if phase == .neutralDelay {
            guard let at=capabilitiesSentAt,let lane else {return close("Missing negotiation")}
            guard now-at<MobileAirSendGate.ackNS else {return close("Neutral setup overdue")}
            guard now-at>=MobileAirSendGate.paceNS else {return .wait}
            guard var sender=MobileAirSendGate(lane:lane,initialSequence:1) else {return close("Invalid lane")}
            let result=sender.begin(now:now);gate=sender;phase = .neutralACK
            return translate(result)
        }
        if phase == .neutralACK || phase == .ready {
            guard var sender=gate else {return close("Missing sender")}
            let result=sender.poll(now:now);gate=sender
            return translate(result)
        }
        return .wait
    }
    public mutating func offer(_ output:MobileAirOutput,observedAt:Int64,now:Int64,
                               stringDeadlines: [Int: Int64] = [:])->Action {
        if let failure=check(now){return failure}
        // No gesture buffering across negotiation. No pre-ACK observation
        // may become an attack; sender also checks the observation watermark.
        guard phase == .ready else {return poll(now:now)}
        guard var sender=gate else {return close("Missing sender")}
        let result=sender.offer(output,observedAt:observedAt,now:now,stringDeadlines:stringDeadlines);gate=sender
        return translate(result)
    }
    public mutating func abort()->Action {close("Stopped explicitly")}
}
