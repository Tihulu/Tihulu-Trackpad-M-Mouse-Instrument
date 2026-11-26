#if os(macOS)
import Foundation
import CoreMIDI
import NoSpeakerCore

/// Explicit, one-shot playback on a dedicated virtual MIDI source.
/// No physical destination is selected, no global panic is sent and no
/// hardware, haptics or capture is opened. Retain this instance until
/// cleanup and endpoint disposal are confirmed.
@MainActor
public final class NativeMIDIPlayback {
    public enum Failure: LocalizedError {
        case invalidLifecycle, capacity, native(String,Int32), cleanupPending, sourceIdentityLost, sessionFailure(String,String)
        public var errorDescription:String? {
            switch self {
            case .invalidLifecycle: return "Playback is not in the required lifecycle state."
            case .capacity: return "At most four native playback sources may be open. Close owned sessions or quit and relaunch if recovery is unconfirmed."
            case .native(let action,let code): return "MIDI "+action+" failed ("+String(code)+")."
            case .cleanupPending: return "MIDI note cleanup is unconfirmed; retain the source and retry."
            case .sourceIdentityLost: return "Original MIDI source identity is unconfirmed; never send to or dispose a replacement."
            case .sessionFailure(let primary,let cleanup): return "Playback failed ("+primary+"); cleanup failed ("+cleanup+"). Retain session for recovery."
            }
        }
    }
    public struct Report: Encodable, Sendable {
        public let state:String
        public let cancelled:Bool
        public let cleanupConfirmed:Bool
        public let outstandingNotes:Int
        public let receiverConfirmed:Bool
        public let faultReason:String?
        public let maximumObservedLatenessNS:UInt64
        public let maximumIdentityCheckNS:UInt64
        public let maximumNativeSendNS:UInt64
        /// Host scheduling telemetry, not physical MIDI latency.
        public let maximumWakeLatenessNS:UInt64
    }

    /// The successful close report is distinct from receiver confirmation.
    public struct ClosedSessionReport: Encodable, Sendable {
        public let playback:Report
        public let completed:Bool
        public let sourceDisposed:Bool
        public let recoveryRequired:Bool
    }

    public struct Lifecycle: Encodable, Sendable {
        public let state:String
        public let sourceOpen:Bool
        public let running:Bool
        public let identityRetired:Bool
        public let disposalFailed:Bool
        public let outstandingNotes:Int
        public let recoveryRequired:Bool
    }

    /// Local ledger state, not proof that the remote receiver is silent.
    public var lifecycle:Lifecycle {
        .init(state:player.state.rawValue,sourceOpen:endpoint != 0,running:running || closingSession,
              identityRetired:identityRetired,disposalFailed:disposalFailed,outstandingNotes:player.outstanding.count,
              recoveryRequired:identityRetired || disposalFailed || (player.state != .playing && !player.outstanding.isEmpty))
    }

    // Library callers may open more than one session. Keep a bounded
    // process-wide inventory, including unidentified or abandoned handles.
    public static let maximumOpenSources=4
    private static var openSlots:Set<UUID>=[]
    private let slot=UUID()

    public let sourceName = "TIHULU SDK Playback "+UUID().uuidString
    private var endpoint=MIDIEndpointRef()
    private var sourceID:Int32=0
    private var identityRetired=false
    private var disposalFailed=false
    private var wasCancelled=false
    private var player:BoundedMIDIPlayback
    private var opened=false
    private var running=false
    // A compound operation owns the endpoint until disposal or failure,
    // including the actor-resumption boundary after the async run.
    private var closingSession=false
    private var stopRequested=false
    private var maximumIdentityCheckNS:UInt64=0
    private var maximumNativeSendNS:UInt64=0
    private var maximumWakeLatenessNS:UInt64=0

    public init(clip:MIDIClip) throws {
        player=try BoundedMIDIPlayback(clip:clip)
    }

    /// Reuse the exact validated schedule returned by the portable planner.
    /// A previously started copy cannot be turned into a fresh session.
    public init(prepared:BoundedMIDIPlayback) throws {
        guard prepared.state == .ready,prepared.outstanding.isEmpty else { throw Failure.invalidLifecycle }
        player=prepared
    }

    /// Register a unique virtual source, but send no messages until run().
    public func open() throws {
        try open(onCreated:{ _ in })
    }

    // Internal synchronous fixture seam; never exposed through CLI.
    func open(onCreated:(MIDIEndpointRef)->Void) throws {
        guard !opened,!running,endpoint==0,player.state == .ready else {
            throw Failure.invalidLifecycle
        }
        try Task.checkCancellation()
        guard Self.openSlots.count<Self.maximumOpenSources,
              Self.openSlots.insert(slot).inserted else { throw Failure.capacity }
        // Release admission only if no handle was obtained. A quarantined
        // or abandoned endpoint must continue consuming its slot.
        defer { if endpoint==0 { Self.openSlots.remove(slot) } }
        let client=try MIDIProcessClient.shared.acquire()
        try Task.checkCancellation()
        var source=MIDIEndpointRef()
        let status=MIDISourceCreate(client,sourceName as CFString,&source)
        guard source != 0 else {
            throw Failure.native("source",status==noErr ? -1 : status)
        }
        // Track any returned handle before attempting identity inspection.
        // An unverified handle is quarantined, not disposed or retried
        // against a potentially replaced endpoint. Exclude it from legacy
        // automatic input attachment while recovery remains unresolved.
        endpoint=source
        opened=true
        MIDIProcessClient.shared.registerIsolatedSource(source)
        guard status==noErr else {
            identityRetired=true
            player.abort { _ in false }
            throw Failure.native("source",status)
        }
        onCreated(source)
        var uid:Int32=0
        let identified=MIDIObjectGetIntegerProperty(source,kMIDIPropertyUniqueID,&uid)
        guard identified==noErr,uid != 0,Self.matches(source:source,id:uid,name:sourceName) else {
            identityRetired=true
            player.abort { _ in false }
            throw Failure.sourceIdentityLost
        }
        sourceID=uid
    }

    /// A concurrent stop request is observed before the next onset, with
    /// at most a 20 ms planned sleep. Native calls can themselves block.
    public func requestStop() { if player.state == .ready || player.state == .playing { stopRequested=true } }

    public func run() async throws -> Report {
        guard !closingSession else { throw Failure.invalidLifecycle }
        return try await runPlayback()
    }

    private func runPlayback() async throws -> Report {
        guard opened,endpoint != 0,!running,player.state == .ready,!identityRetired else {
            throw Failure.invalidLifecycle
        }
        running=true
        defer { running=false }
        let source=endpoint,id=sourceID,name=sourceName
        // Capture the identity gate separately from the mutable playback ledger.
        let gate=IdentityGate(source:source,id:id,name:name,retired:identityRetired)
        defer {
            recordGate(gate)
            identityRetired=gate.retired
            wasCancelled=wasCancelled || stopRequested || Task.isCancelled
        }
        // Validate even when a stop was requested before the first note.
        // Cancellation must not disguise a retired source as a clean stop.
        guard gate.validate() else {
            player.abort { gate.send($0) }
            throw Failure.sourceIdentityLost
        }
        if stopRequested || Task.isCancelled {
            player.stop { gate.send($0) }
            recordGate(gate)
            return report(cancelled:true)
        }
        // Anchor once to the suspending monotonic clock, like uptime.
        // A relative Task.sleep may allow scheduler coalescing. Request
        // exact absolute wake targets without relaxing the core fence.
        // The OS can still delay this task; late events remain faults.
        let waitClock=SuspendingClock()
        let waitAnchor=waitClock.now
        let uptimeAnchor=Self.now()
        _=try player.begin(now:uptimeAnchor)
        while player.state == .playing {
            // Check the bound source even during initial/trailing rests.
            guard gate.validate() else {
                player.abort { gate.send($0) }
                break
            }
            if stopRequested || Task.isCancelled {
                player.stop { gate.send($0) }
                break
            }
            let cancelled=stopRequested
            player.advance(now:Self.now(),refreshNow:{ Self.now() },shouldStop:{ cancelled || Task.isCancelled },
                           authorizeOnset:{ gate.authorizeOnset() }) { command in
                if command.value > 0 && (cancelled || Task.isCancelled) { return false }
                return gate.send(command)
            }
            guard let deadline=player.nextDeadline else { break }
            let current=Self.now()
            if let wakeTarget=Self.nextWakeTarget(deadline:deadline,current:current) {
                guard wakeTarget>=uptimeAnchor,
                      let offset=Int64(exactly:wakeTarget-uptimeAnchor) else {
                    player.abort { gate.send($0) }
                    break
                }
                do {
                    try await waitClock.sleep(until:waitAnchor.advanced(by:.nanoseconds(offset)),tolerance:.zero)
                    let woke=Self.now()
                    if woke>=wakeTarget {
                        maximumWakeLatenessNS=max(maximumWakeLatenessNS,woke-wakeTarget)
                    }
                } catch {
                    player.stop { gate.send($0) }
                    break
                }
            }
            // If an event became due during synchronous work, advance
            // immediately rather than yield the executor once more.
            // The next advance either consumes a due edge or terminates;
            // a future deadline still suspends for at most the poll cap.
        }
        // A final check covers the last send and cancellation while sleeping.
        if !gate.validate() {
            player.abort { gate.send($0) }
            player.invalidateTerminalResult()
        }
        identityRetired=gate.retired
        recordGate(gate)
        return report(cancelled:stopRequested || Task.isCancelled)
    }

    /// Explicitly opened one-shot session. Complete the operation, retry
    /// owned note debt once, then dispose only the original endpoint.
    /// The caller retains this instance if any stage requires recovery.
    /// Never automatically opens a device or treats a fault as success.
    public func runAndClose() async throws -> ClosedSessionReport {
        try await runAndClose(beforeClose:{})
    }

    // Internal fixture seam verifies the exclusive finalization boundary.
    func runAndClose(beforeClose:()->Void) async throws -> ClosedSessionReport {
        guard opened,endpoint != 0,!running,!closingSession,player.state == .ready else {
            throw Failure.invalidLifecycle
        }
        closingSession=true
        defer { closingSession=false }
        let initial:Report
        do {
            initial=try await runPlayback()
        } catch {
            let primary=error
            do { try closePlayback() }
            catch { throw Failure.sessionFailure(primary.localizedDescription,error.localizedDescription) }
            throw primary
        }
        beforeClose()
        let final=initial.outstandingNotes>0 ? try retryPlaybackCleanup() : initial
        guard final.cleanupConfirmed else {
            if identityRetired { throw Failure.sourceIdentityLost }
            throw Failure.cleanupPending
        }
        try closePlayback()
        // Cancellation may arrive after the async playback return but
        // before the compound operation disposes its endpoint. Finish
        // owned cleanup, yet never report the compound task as completed.
        wasCancelled = wasCancelled || final.cancelled || Task.isCancelled
        let closed = report(cancelled:wasCancelled)
        return .init(playback:closed,completed:closed.state=="finished" && !closed.cancelled,
                     sourceDisposed:endpoint==0,recoveryRequired:lifecycle.recoveryRequired)
    }

    /// Retry only outstanding note-offs on the exact original endpoint.
    public func retryCleanup() throws -> Report {
        guard !closingSession else { throw Failure.invalidLifecycle }
        return try retryPlaybackCleanup()
    }

    private func retryPlaybackCleanup() throws -> Report {
        guard opened,endpoint != 0,!running,player.state != .ready,
              player.state != .playing else { throw Failure.invalidLifecycle }
        let gate=IdentityGate(source:endpoint,id:sourceID,name:sourceName,retired:identityRetired)
        defer { identityRetired=gate.retired;recordGate(gate) }
        // An empty note ledger is not evidence that the endpoint still
        // belongs to this session. Do not report successful recovery
        // against a retired or replaced source.
        guard gate.validate() else {
            player.invalidateTerminalResult()
            throw Failure.sourceIdentityLost
        }
        player.retryCleanup { gate.send($0) }
        guard gate.validate() else {
            player.invalidateTerminalResult()
            throw Failure.sourceIdentityLost
        }
        recordGate(gate)
        return report(cancelled:wasCancelled)
    }

    private func recordGate(_ gate:IdentityGate) {
        maximumIdentityCheckNS=max(maximumIdentityCheckNS,gate.maximumIdentityCheckNS)
        maximumNativeSendNS=max(maximumNativeSendNS,gate.maximumNativeSendNS)
    }

    /// Never silently discard note debt or a failed endpoint disposal.
    public func close() throws {
        guard !closingSession else { throw Failure.invalidLifecycle }
        try closePlayback()
    }

    private func closePlayback() throws {
        guard opened,endpoint != 0,!running else { throw Failure.invalidLifecycle }
        guard player.outstanding.isEmpty else { throw Failure.cleanupPending }
        let source=endpoint
        guard !identityRetired,Self.matches(source:source,id:sourceID,name:sourceName) else {
            identityRetired=true
            player.abort { _ in false }
            player.invalidateTerminalResult()
            throw Failure.sourceIdentityLost
        }
        if player.state == .ready { player.stop { _ in false } }
        let status=MIDIEndpointDispose(source)
        guard status==noErr else {
            disposalFailed=true
            throw Failure.native("source disposal",status)
        }
        disposalFailed=false
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
        endpoint=0
        Self.openSlots.remove(slot)
    }

    private func report(cancelled:Bool) -> Report {
        .init(state:player.state.rawValue,cancelled:cancelled,
              cleanupConfirmed:player.outstanding.isEmpty && !identityRetired && !disposalFailed,
              outstandingNotes:player.outstanding.count,receiverConfirmed:false,
              faultReason:identityRetired ? "sourceIdentityLost" : player.fault?.rawValue,
              maximumObservedLatenessNS:player.maximumObservedLatenessNS,
              maximumIdentityCheckNS:maximumIdentityCheckNS,maximumNativeSendNS:maximumNativeSendNS,
              maximumWakeLatenessNS:maximumWakeLatenessNS)
    }

    // Nil means a due deadline, not permission to sleep or yield.
    // Subtract before adding so the target cannot overflow UInt64.
    nonisolated static func nextWakeTarget(deadline:UInt64,current:UInt64) -> UInt64? {
        guard deadline>current else { return nil }
        return current+min(deadline-current,20_000_000)
    }

    private nonisolated static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func matches(source:MIDIEndpointRef,id:Int32,name:String) -> Bool {
        var actual:Int32=0
        guard source != 0,id != 0,
              MIDIObjectGetIntegerProperty(source,kMIDIPropertyUniqueID,&actual)==noErr,actual==id else { return false }
        var label:Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(source,kMIDIPropertyName,&label)==noErr,let label else { return false }
        return label.takeRetainedValue() as String == name
    }

    @MainActor private final class IdentityGate {
        let source:MIDIEndpointRef
        let id:Int32
        let name:String
        private(set) var retired:Bool
        private(set) var maximumIdentityCheckNS:UInt64=0
        private(set) var maximumNativeSendNS:UInt64=0
        private var onsetAuthorized=false
        init(source:MIDIEndpointRef,id:Int32,name:String,retired:Bool) {
            self.source=source;self.id=id;self.name=name;self.retired=retired
        }
        func validate()->Bool {
            let started=NativeMIDIPlayback.now()
            defer { maximumIdentityCheckNS=max(maximumIdentityCheckNS,NativeMIDIPlayback.now()-started) }
            guard !retired,NativeMIDIPlayback.matches(source:source,id:id,name:name) else {
                retired=true
                return false
            }
            return true
        }
        func authorizeOnset()->Bool {
            onsetAuthorized=validate()
            return onsetAuthorized
        }
        func send(_ command:SensorCommand)->Bool {
            // Onsets use the immediately preceding identity validation,
            // followed by the core's fresh clock/cancellation check.
            // No suspension or second potentially slow property query
            // occurs between that check and the native send.
            let authorized=onsetAuthorized
            onsetAuthorized=false
            if command.value>0 {
                guard authorized,!retired else { return false }
            } else {
                // Cleanup always independently verifies the old identity.
                guard validate() else { return false }
            }
            let started=NativeMIDIPlayback.now()
            defer { maximumNativeSendNS=max(maximumNativeSendNS,NativeMIDIPlayback.now()-started) }
            return NativeMIDIPlayback.send(command,source:source)
        }
    }

    private static func send(_ command:SensorCommand,source:MIDIEndpointRef) -> Bool {
        let target=command.destination
        guard source != 0,target.kind == .note,target.isValid,
              (0...127).contains(command.value) else { return false }
        let bytes:[UInt8]=[UInt8((command.value>0 ? 0x90 : 0x80)|target.channel),
                           UInt8(target.number),UInt8(command.value)]
        var list=MIDIPacketList()
        let packet=MIDIPacketListInit(&list)
        let added=bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(&list,MemoryLayout<MIDIPacketList>.size,packet,
                              0,buffer.count,buffer.baseAddress!) != nil
        }
        return added && MIDIReceived(source,&list)==noErr
    }
}
#endif
