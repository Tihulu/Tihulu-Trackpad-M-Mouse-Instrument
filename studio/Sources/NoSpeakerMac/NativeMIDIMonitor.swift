#if os(macOS)
import Foundation
import CoreMIDI
import NoSpeakerCore

/// Explicit, bounded receive-only observation of one existing source.
/// No packet contents, MIDI output, virtual endpoints, or automatic rebind.
@MainActor
public enum NativeMIDIMonitor {
    public struct Report: Encodable, Sendable {
        public let requestedSeconds:Int
        public let callbackCount:UInt64
        public let packetCount:UInt64
        public let sourceStillPresent:Bool
        public let cleanupConfirmed:Bool
    }
    public enum Failure: LocalizedError {
        case invalidSelection, sourceUnavailable, ambiguousSource, sourceInventoryTooLarge
        case capacity, recoveryRequired
        case native(String,Int32)
        public var errorDescription:String? {
            switch self {
            case .invalidSelection: return "Use an exact source display name and a duration from 1 to 10 seconds."
            case .sourceUnavailable: return "Selected MIDI source is unavailable."
            case .ambiguousSource: return "More than one MIDI source has that name; observation refused."
            case .sourceInventoryTooLarge: return "MIDI source inventory exceeds the inspection limit."
            case .capacity: return "At most four simultaneous MIDI observations are allowed."
            case .recoveryRequired: return "A previous MIDI receive port could not be disposed. Quit and relaunch before opening another observation."
            case .native(let step,let status): return "MIDI "+step+" failed ("+String(status)+")."
            }
        }
    }
    private static var slots=BoundedMIDIObservationSlots()

    // Construct native callbacks outside MainActor. CoreMIDI delivers
    // them on its own threads; actor-isolated closure inference would trap.
     private nonisolated static func makePort(_ client:MIDIClientRef,_ port:inout MIDIPortRef,
                                              counter:BoundedMIDIObservation)->OSStatus {
        MIDIInputPortCreateWithProtocol(client,"TIHULU Receive Only" as CFString,._1_0,&port) { @Sendable list,_ in
            counter.record(packets:list.pointee.numPackets,now:DispatchTime.now().uptimeNanoseconds)
        }
    }
    private static func present(_ endpoint:MIDIEndpointRef)->Bool {
        let count=MIDIGetNumberOfSources()
        guard count<=256 else { return false }
        return (0..<count).contains { MIDIGetSource($0)==endpoint }
    }
    private struct SourceIdentity: Equatable {
        let endpoint:MIDIEndpointRef
        let uniqueID:Int32
        let displayName:String
    }
    private static func identity(_ endpoint:MIDIEndpointRef)->SourceIdentity? {
        guard present(endpoint) else { return nil }
        var uid:Int32=0
        guard MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&uid)==noErr,uid != 0 else { return nil }
        var label:Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&label)==noErr,let label else { return nil }
        return .init(endpoint:endpoint,uniqueID:uid,displayName:label.takeRetainedValue() as String)
    }
    static func resolve(name:String) throws -> MIDIEndpointRef {
        guard !name.isEmpty,name.utf8.count<=512,
              !name.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidSelection
        }
        let count=MIDIGetNumberOfSources()
        guard count<=256 else { throw Failure.sourceInventoryTooLarge }
        var matches:Set<MIDIEndpointRef> = []
        for index in 0..<count {
            let endpoint=MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            var label:Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&label)==noErr,
               let label,label.takeRetainedValue() as String == name { matches.insert(endpoint) }
        }
        guard matches.count<=1 else { throw Failure.ambiguousSource }
        guard let endpoint=matches.first,present(endpoint) else { throw Failure.sourceUnavailable }
        return endpoint
    }
    public static func observe(sourceName:String,seconds:Int) async throws -> Report {
        try await observe(sourceName:sourceName,seconds:seconds,onConnected:{})
    }

    // Internal readiness seam for the isolated CI fixture. No hook is
    // exposed through the public API or native CLI.
    static func observe(sourceName:String,seconds:Int,onConnected:() throws -> Void) async throws -> Report {
        guard (1...10).contains(seconds) else { throw Failure.invalidSelection }
        try Task.checkCancellation()
        let source=try resolve(name:sourceName)
        guard let bound=identity(source),bound.displayName==sourceName else { throw Failure.sourceUnavailable }
        let counter=BoundedMIDIObservation()
        guard !slots.recoveryRequired else { throw Failure.recoveryRequired }
        guard let slot=slots.reserve() else { throw Failure.capacity }
        return try await withTaskCancellationHandler {
            var port=MIDIPortRef(),connected=false
            var disposalConfirmed=true
            var cleanupResult:(status:OSStatus,identityValid:Bool)?
            defer { _=slots.finish(slot,portDisposalConfirmed:disposalConfirmed) }
            // Cleanup is attempted on every exit, including setup errors and cancellation.
            @MainActor func cleanup()->(status:OSStatus,identityValid:Bool) {
                if let cleanupResult { return cleanupResult }
                _ = counter.stop()
                var result:OSStatus=noErr
                let identityValid=identity(source)==bound
                if connected {
                    // Never disconnect using a retired/reused source handle.
                    // Disposing our own input port removes its subscriptions.
                    if identityValid {
                        let status=MIDIPortDisconnectSource(port,source)
                        if status != noErr { result=status }
                    }
                    connected=false
                }
                if port != 0 {
                    let status=MIDIPortDispose(port);port=0
                    disposalConfirmed=status==noErr
                    if status != noErr && result == noErr { result=status }
                }
                let outcome=(status:result,identityValid:identityValid && identity(source)==bound)
                cleanupResult=outcome
                return outcome
            }
            do {
                // Keep the process client alive across observations and
                // playback sessions. Each observation still owns exactly
                // its input port and never disposes another session's port.
                let client:MIDIClientRef
                do { client=try MIDIProcessClient.shared.acquire() }
                catch MIDIHapticError.client(let status) { throw Failure.native("client",status) }
                try Task.checkCancellation()
                var status=makePort(client,&port,counter:counter)
                disposalConfirmed=port==0
                guard status==noErr,port != 0 else { throw Failure.native("input port",status==noErr ? -1 : status) }
                guard try resolve(name:sourceName)==source,identity(source)==bound else { throw Failure.sourceUnavailable }
                let clock=ContinuousClock()
                let deadline=clock.now.advanced(by:.seconds(seconds))
                try Task.checkCancellation()
                guard counter.begin(now:DispatchTime.now().uptimeNanoseconds,seconds:seconds) else {
                    try Task.checkCancellation()
                    throw Failure.invalidSelection
                }
                try Task.checkCancellation()
                status=MIDIPortConnectSource(port,source,nil)
                guard status==noErr else { throw Failure.native("connect",status) }
                connected=true
                try Task.checkCancellation()
                guard identity(source)==bound else { throw Failure.sourceUnavailable }
                try onConnected()
                try Task.checkCancellation()
                // Poll only the bound endpoint, never resolve/reconnect a new one.
                // Identity loss is terminal even if the name later reappears.
                var available=identity(source)==bound
                while available && clock.now<deadline {
                    try await clock.sleep(until:min(deadline,clock.now.advanced(by:.milliseconds(100))))
                    try Task.checkCancellation()
                    available=identity(source)==bound
                }
                let counts=counter.stop()
                try Task.checkCancellation()
                guard available else { throw Failure.sourceUnavailable }
                let cleaned=cleanup()
                guard cleaned.status==noErr else { throw Failure.native("cleanup",cleaned.status) }
                guard cleaned.identityValid else { throw Failure.sourceUnavailable }
                try Task.checkCancellation()
                return .init(requestedSeconds:seconds,callbackCount:counts.callbacks,packetCount:counts.packets,
                             sourceStillPresent:true,cleanupConfirmed:true)
            } catch {
                // Preserve a cleanup failure even when the primary error
                // was cancellation or identity loss; never claim clean exit.
                let cleaned=cleanup()
                guard cleaned.status==noErr else { throw Failure.native("cleanup after interruption",cleaned.status) }
                throw error
            }
        } onCancel: {
            // Retire callback admission immediately, even if MainActor
            // has not yet resumed to dispose the native input port.
            _ = counter.stop()
        }
    }
}
#endif
