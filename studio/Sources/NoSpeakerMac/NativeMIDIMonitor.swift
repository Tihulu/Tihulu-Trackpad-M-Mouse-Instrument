#if os(macOS)
import Foundation
import CoreMIDI

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
        case native(String,Int32)
        public var errorDescription:String? {
            switch self {
            case .invalidSelection: return "Use an exact source display name and a duration from 1 to 10 seconds."
            case .sourceUnavailable: return "Selected MIDI source is unavailable."
            case .ambiguousSource: return "More than one MIDI source has that name; observation refused."
            case .sourceInventoryTooLarge: return "MIDI source inventory exceeds the inspection limit."
            case .native(let step,let status): return "MIDI "+step+" failed ("+String(status)+")."
            }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var accepting = false
        private var callbacks:UInt64 = 0
        private var packets:UInt64 = 0
        func start() { lock.lock(); accepting=true;lock.unlock() }
        func record(_ count:UInt32) {
            lock.lock();defer { lock.unlock() }
            guard accepting else { return }
            if callbacks < UInt64.max { callbacks += 1 }
            packets += min(UInt64(count),UInt64.max-packets)
        }
        func stop()->(UInt64,UInt64) {
            lock.lock();defer { lock.unlock() }
            accepting=false;return (callbacks,packets)
        }
    }
    private static func present(_ endpoint:MIDIEndpointRef)->Bool {
        let count=MIDIGetNumberOfSources()
        guard count<=256 else { return false }
        return (0..<count).contains { MIDIGetSource($0)==endpoint }
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
        let counter=Counter()
        var client=MIDIClientRef(),port=MIDIPortRef(),connected=false
        // Cleanup is attempted on every exit, including setup errors and cancellation.
        func cleanup()->OSStatus {
            _ = counter.stop()
            var result:OSStatus=noErr
            if connected {
                let status=MIDIPortDisconnectSource(port,source)
                if status != noErr { result=status }
                connected=false
            }
            if port != 0 {
                let status=MIDIPortDispose(port);port=0
                if status != noErr && result == noErr { result=status }
            }
            if client != 0 {
                let status=MIDIClientDispose(client);client=0
                if status != noErr && result == noErr { result=status }
            }
            return result
        }
        defer { _ = cleanup() }
        var status=MIDIClientCreateWithBlock("TIHULU Native Observer" as CFString,&client) { _ in }
        guard status==noErr else { throw Failure.native("client",status) }
        status=MIDIInputPortCreateWithProtocol(client,"TIHULU Receive Only" as CFString,._1_0,&port) { list,_ in
            // Inspect only the count in the trusted CoreMIDI list header.
            counter.record(list.pointee.numPackets)
        }
        guard status==noErr else { throw Failure.native("input port",status) }
        guard try resolve(name:sourceName)==source else { throw Failure.sourceUnavailable }
        counter.start()
        status=MIDIPortConnectSource(port,source,nil)
        guard status==noErr else { throw Failure.native("connect",status) }
        connected=true
        try onConnected()
        try await Task.sleep(for:.seconds(seconds))
        try Task.checkCancellation()
        let counts=counter.stop()
        let available=present(source)
        status=cleanup()
        guard status==noErr else { throw Failure.native("cleanup",status) }
        return .init(requestedSeconds:seconds,callbackCount:counts.0,packetCount:counts.1,
                     sourceStillPresent:available,cleanupConfirmed:true)
    }
}
#endif
