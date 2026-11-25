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
        case invalidLifecycle, native(String,Int32), cleanupPending
        public var errorDescription:String? {
            switch self {
            case .invalidLifecycle: return "Playback is not in the required lifecycle state."
            case .native(let action,let code): return "MIDI "+action+" failed ("+String(code)+")."
            case .cleanupPending: return "MIDI note cleanup is unconfirmed; retain the source and retry."
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

    public let sourceName = "TIHULU SDK Playback "+UUID().uuidString
    private var endpoint=MIDIEndpointRef()
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
        endpoint=source
        opened=true
        MIDIProcessClient.shared.registerIsolatedSource(source)
    }

    /// A concurrent stop request is observed before the next onset, with
    /// at most a 20 ms planned sleep. Native calls can themselves block.
    public func requestStop() { stopRequested=true }

    public func run() async throws -> Report {
        guard opened,endpoint != 0,!running,player.state == .ready else {
            throw Failure.invalidLifecycle
        }
        running=true
        defer { running=false }
        let source=endpoint
        if stopRequested || Task.isCancelled {
            player.stop { Self.send($0,source:source) }
            return report(cancelled:true)
        }
        _=try player.begin(now:Self.now())
        while player.state == .playing {
            if stopRequested || Task.isCancelled {
                player.stop { Self.send($0,source:source) }
                break
            }
            let cancelled=stopRequested
            player.advance(now:Self.now(),refreshNow:{ Self.now() }) { command in
                if command.value > 0 && (cancelled || Task.isCancelled) { return false }
                return Self.send(command,source:source)
            }
            guard let deadline=player.nextDeadline else { break }
            let current=Self.now()
            if deadline>current {
                do { try await Task.sleep(nanoseconds:min(deadline-current,20_000_000)) }
                catch {
                    player.stop { Self.send($0,source:source) }
                    break
                }
            } else {
                await Task.yield()
            }
        }
        return report(cancelled:stopRequested || Task.isCancelled)
    }

    /// Retry only outstanding note-offs on the exact original endpoint.
    public func retryCleanup() throws -> Report {
        guard opened,endpoint != 0,!running,player.state != .ready,
              player.state != .playing else { throw Failure.invalidLifecycle }
        let source=endpoint
        player.retryCleanup { Self.send($0,source:source) }
        return report(cancelled:stopRequested)
    }

    /// Never silently discard note debt or a failed endpoint disposal.
    public func close() throws {
        guard opened,endpoint != 0,!running else { throw Failure.invalidLifecycle }
        guard player.outstanding.isEmpty else { throw Failure.cleanupPending }
        let source=endpoint
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
