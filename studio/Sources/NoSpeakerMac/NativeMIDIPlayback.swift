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
        case invalidLifecycle, native(String,Int32), cleanupPending, sourceIdentityLost
        public var errorDescription:String? {
            switch self {
            case .invalidLifecycle: return "Playback is not in the required lifecycle state."
            case .native(let action,let code): return "MIDI "+action+" failed ("+String(code)+")."
            case .cleanupPending: return "MIDI note cleanup is unconfirmed; retain the source and retry."
            case .sourceIdentityLost: return "Original MIDI source identity is unconfirmed; never send to or dispose a replacement."
            }
        }
    }
    public struct Report: Encodable, Sendable {
        public let state:String
        public let cancelled:Bool
        public let cleanupConfirmed:Bool
        public let outstandingNotes:Int
        public let receiverConfirmed:Bool
    }

    public struct Lifecycle: Encodable, Sendable {
        public let state:String
        public let sourceOpen:Bool
        public let running:Bool
        public let identityRetired:Bool
        public let outstandingNotes:Int
        public let recoveryRequired:Bool
    }

    /// Local ledger state, not proof that the remote receiver is silent.
    public var lifecycle:Lifecycle {
        .init(state:player.state.rawValue,sourceOpen:endpoint != 0,running:running,
              identityRetired:identityRetired,outstandingNotes:player.outstanding.count,
              recoveryRequired:identityRetired || (player.state != .playing && !player.outstanding.isEmpty))
    }

    public let sourceName = "TIHULU SDK Playback "+UUID().uuidString
    private var endpoint=MIDIEndpointRef()
    private var sourceID:Int32=0
    private var identityRetired=false
    private var wasCancelled=false
    private var player:BoundedMIDIPlayback
    private var opened=false
    private var running=false
    private var stopRequested=false

    public init(clip:MIDIClip) throws {
        player=try BoundedMIDIPlayback(clip:clip)
    }

    /// Register a unique virtual source, but send no messages until run().
    public func open() throws {
        guard !opened,!running,endpoint==0,player.state == .ready else {
            throw Failure.invalidLifecycle
        }
        try Task.checkCancellation()
        let client=try MIDIProcessClient.shared.acquire()
        var source=MIDIEndpointRef()
        let status=MIDISourceCreate(client,sourceName as CFString,&source)
        guard status==noErr,source != 0 else {
            throw Failure.native("source",status)
        }
        var uid:Int32=0
        let identified=MIDIObjectGetIntegerProperty(source,kMIDIPropertyUniqueID,&uid)
        guard identified==noErr,uid != 0,Self.matches(source:source,id:uid,name:sourceName) else {
            let disposed=MIDIEndpointDispose(source)
            guard disposed==noErr else { throw Failure.native("unidentified source disposal",disposed) }
            throw Failure.sourceIdentityLost
        }
        endpoint=source
        sourceID=uid
        opened=true
        MIDIProcessClient.shared.registerIsolatedSource(source)
    }

    /// A concurrent stop request is observed before the next onset, with
    /// at most a 20 ms planned sleep. Native calls can themselves block.
    public func requestStop() { if player.state == .ready || player.state == .playing { stopRequested=true } }

    public func run() async throws -> Report {
        guard opened,endpoint != 0,!running,player.state == .ready else {
            throw Failure.invalidLifecycle
        }
        running=true
        defer { running=false }
        let source=endpoint,id=sourceID,name=sourceName
        // Capture the identity gate separately from the mutable playback ledger.
        let gate=IdentityGate(source:source,id:id,name:name,retired:identityRetired)
        defer { identityRetired=gate.retired;wasCancelled=wasCancelled || stopRequested || Task.isCancelled }
        if stopRequested || Task.isCancelled {
            player.stop { gate.send($0) }
            return report(cancelled:true)
        }
        guard gate.validate() else {
            player.abort { gate.send($0) }
            throw Failure.sourceIdentityLost
        }
        _=try player.begin(now:Self.now())
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
            player.advance(now:Self.now(),refreshNow:{ Self.now() },shouldStop:{ cancelled || Task.isCancelled }) { command in
                if command.value > 0 && (cancelled || Task.isCancelled) { return false }
                return gate.send(command)
            }
            guard let deadline=player.nextDeadline else { break }
            let current=Self.now()
            if deadline>current {
                do { try await Task.sleep(nanoseconds:min(deadline-current,20_000_000)) }
                catch {
                    player.stop { gate.send($0) }
                    break
                }
            } else {
                await Task.yield()
            }
        }
        identityRetired=gate.retired
        return report(cancelled:stopRequested || Task.isCancelled)
    }

    /// Retry only outstanding note-offs on the exact original endpoint.
    public func retryCleanup() throws -> Report {
        guard opened,endpoint != 0,!running,player.state != .ready,
              player.state != .playing else { throw Failure.invalidLifecycle }
        let gate=IdentityGate(source:endpoint,id:sourceID,name:sourceName,retired:identityRetired)
        defer { identityRetired=gate.retired }
        player.retryCleanup { gate.send($0) }
        return report(cancelled:wasCancelled)
    }

    /// Never silently discard note debt or a failed endpoint disposal.
    public func close() throws {
        guard opened,endpoint != 0,!running else { throw Failure.invalidLifecycle }
        guard player.outstanding.isEmpty else { throw Failure.cleanupPending }
        let source=endpoint
        guard !identityRetired,Self.matches(source:source,id:sourceID,name:sourceName) else {
            identityRetired=true
            throw Failure.sourceIdentityLost
        }
        if player.state == .ready { player.stop { _ in false } }
        let status=MIDIEndpointDispose(source)
        guard status==noErr else { throw Failure.native("source disposal",status) }
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
        endpoint=0
    }

    private func report(cancelled:Bool) -> Report {
        .init(state:player.state.rawValue,cancelled:cancelled,
              cleanupConfirmed:player.outstanding.isEmpty,
              outstandingNotes:player.outstanding.count,receiverConfirmed:false)
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
        init(source:MIDIEndpointRef,id:Int32,name:String,retired:Bool) {
            self.source=source;self.id=id;self.name=name;self.retired=retired
        }
        func validate()->Bool {
            guard !retired,NativeMIDIPlayback.matches(source:source,id:id,name:name) else {
                retired=true
                return false
            }
            return true
        }
        func send(_ command:SensorCommand)->Bool {
            guard validate() else { return false }
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
