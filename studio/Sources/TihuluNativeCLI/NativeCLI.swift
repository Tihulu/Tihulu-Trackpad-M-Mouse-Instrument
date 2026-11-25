import Foundation
import NoSpeakerProcessSignals
import NoSpeakerCore
#if os(macOS)
import NoSpeakerMac
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Independent native diagnostics; the original offline CLI stays pure core.
@main
struct TihuluNativeCLI {
    struct CLIError:Error,CustomStringConvertible {
        let description:String
        init(_ description:String) { self.description = description }
    }
    struct Capabilities: Encodable {
        let schema = 1
        let product = "tihulu-mac-instrument-native"
        let platformSupported:Bool
        let liveOutput = false
        let permissionRequests = false
        let commands = ["capabilities","preflight","midi endpoints [--names]","gamepad devices [--names]","gamepad sample --confirm","midi monitor NAME SECONDS --confirm","session probe SECONDS --confirm","midi plan JSON","midi simulate JSON","midi audit JSON"]
    }
    struct Envelope<Payload:Encodable>: Encodable {
        let schema = 1
        let liveOutput = false
        let command:String
        let result:Payload
    }
    static func encodedReport<T:Encodable>(_ payload:T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        var bytes=try encoder.encode(payload)
        bytes.append(10)
        return bytes
    }
    static func emit<T:Encodable>(_ payload:T) throws {
        try FileHandle.standardOutput.write(contentsOf:encodedReport(payload))
    }

    struct PlaybackPlan:Encodable {
        let noteCount:Int
        let eventCount:Int
        let durationNS:UInt64
        let peakConcurrentNotes:Int
        let hardware = false
        let receiverConfirmed = false
    }

    /// Portable validation only, with no filesystem reads or hardware
    /// access. JSON is an explicit bounded argument, not a filename.
    static func playbackPlan(_ json:String) throws -> PlaybackPlan {
        guard json.utf8.count<=BoundedMIDIPlanInput.maximumBytes else {
            throw BoundedMIDIPlanInput.Failure.invalid
        }
        let (clip,player)=try BoundedMIDIPlanInput.prepare(Data(json.utf8))
        var active=0,peak=0
        for event in player.events {
            active += event.command.value>0 ? 1 : -1
            peak=max(peak,active)
        }
        return .init(noteCount:clip.notes.count,eventCount:player.events.count,
                     durationNS:player.durationNS,peakConcurrentNotes:peak)
    }

    static func playbackSimulation(_ json:String) throws -> BoundedMIDISimulation.Report {
        guard json.utf8.count<=BoundedMIDIPlanInput.maximumBytes else {
            throw BoundedMIDIPlanInput.Failure.invalid
        }
        let (_,player)=try BoundedMIDIPlanInput.prepare(Data(json.utf8))
        return try BoundedMIDISimulation.run(player)
    }

    static func playbackAudit(_ json:String) throws -> BoundedMIDISimulation.Audit {
        guard json.utf8.count<=BoundedMIDIPlanInput.maximumBytes else {
            throw BoundedMIDIPlanInput.Failure.invalid
        }
        let (_,player)=try BoundedMIDIPlanInput.prepare(Data(json.utf8))
        return try BoundedMIDISimulation.audit(player,shouldStop:{
            Task.isCancelled || tihulu_stop_requested() != 0
        })
    }

    struct SessionProbe:Encodable,Sendable {
        let requestedSeconds:Int
        let completed:Bool
        let hardware = false
    }

    private enum StopEvent<T:Sendable>:Sendable {
        case operation(Result<T,any Error>)
        case stop
        case watcherCancelled
    }

    /// One foreground session per process. Only the C bridge runs inside
    /// the signal handler; Swift cancellation and cleanup run normally.
    @MainActor
    static func withProcessStop<T:Encodable & Sendable>(command:String,
        _ operation:@escaping @MainActor @Sendable () async throws -> T) async throws {
        guard tihulu_stop_install()==0 else { throw CLIError("Could not install process stop handlers.") }
        var committed=false
        // After commitment this one-shot CLI exits. Keep the handler in
        // place until process exit rather than reintroducing a race with
        // SIGINT/SIGTERM during the final stdout write.
        defer { if !committed { tihulu_stop_restore() } }
        let outcome:Result<T,any Error> = await withTaskGroup(of:StopEvent<T>.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    guard tihulu_stop_requested()==0 else { throw CancellationError() }
                    return .operation(.success(try await operation()))
                } catch { return .operation(.failure(error)) }
            }
            group.addTask {
                while !Task.isCancelled {
                    if tihulu_stop_requested() != 0 { return .stop }
                    do { try await Task.sleep(nanoseconds:10_000_000) }
                    catch { return .watcherCancelled }
                }
                return .watcherCancelled
            }
            // Always collect the operation result, even when the watcher
            // wins. A cleanup error must not be hidden by cancellation.
            var result:Result<T,any Error>?
            for await event in group {
                if case .operation(let value)=event { result=value }
                group.cancelAll()
            }
            return result ?? .failure(CancellationError())
        }
        let value=try outcome.get()
        // Recheck after both children have exited, not before their cleanup.
        try Task.checkCancellation()
        let report=try encodedReport(Envelope(command:command,result:value))
        guard tihulu_stop_commit()==1 else { throw CancellationError() }
        committed=true
        try FileHandle.standardOutput.write(contentsOf:report)
    }

    @MainActor
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args == ["--help"] || args == ["help"] || args == ["capabilities"] {
                #if os(macOS)
                try emit(Capabilities(platformSupported:true))
                #else
                try emit(Capabilities(platformSupported:false))
                #endif
                return
            }
            if args.count>=2 && Array(args.prefix(2)) == ["midi","plan"] {
                guard args.count==3 else { throw CLIError("Use midi plan JSON; no live output.") }
                try emit(Envelope(command:"midi plan",result:playbackPlan(args[2])))
                return
            }
            if args.count>=2 && Array(args.prefix(2)) == ["midi","simulate"] {
                guard args.count==3 else { throw CLIError("Use midi simulate JSON; no live output.") }
                try emit(Envelope(command:"midi simulate",result:playbackSimulation(args[2])))
                return
            }
            if args.count>=2 && Array(args.prefix(2)) == ["midi","audit"] {
                guard args.count==3 else { throw CLIError("Use midi audit JSON; no live output.") }
                try await withProcessStop(command:"midi audit") {
                    try playbackAudit(args[2])
                }
                return
            }
            if args.count>=2 && Array(args.prefix(2)) == ["session","probe"] {
                guard args.count==4,args[3]=="--confirm",let seconds=Int(args[2]),
                      String(seconds)==args[2],(1...10).contains(seconds) else {
                    throw CLIError("Use session probe SECONDS --confirm (1-10 seconds).")
                }
                try await withProcessStop(command:"session probe") {
                    // Readiness is diagnostic stderr only. JSON is emitted
                    // after successful completion, never on cancellation.
                    FileHandle.standardError.write(Data("session probe ready\n".utf8))
                    defer { FileHandle.standardError.write(Data("session probe cleanup\n".utf8)) }
                    try await Task.sleep(nanoseconds:UInt64(seconds)*1_000_000_000)
                    return SessionProbe(requestedSeconds:seconds,completed:true)
                }
                return
            }
            if args.count>=2 && Array(args.prefix(2)) == ["midi","monitor"] {
                guard args.count==5,args[4]=="--confirm",let seconds=Int(args[3]),
                      String(seconds)==args[3],(1...10).contains(seconds),
                      !args[2].isEmpty,args[2].utf8.count<=512,
                      !args[2].unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else {
                    throw CLIError("Use midi monitor NAME SECONDS --confirm (1-10 seconds).")
                }
                #if os(macOS)
                try await withProcessStop(command:"midi monitor") {
                    try await NativeMIDIMonitor.observe(sourceName:args[2],seconds:seconds)
                }
                #else
                throw CLIError("Native inspection requires macOS.")
                #endif
                return
            }
            if args == ["gamepad","sample","--confirm"] {
                #if os(macOS)
                try emit(Envelope(command:"gamepad sample",result:NativeEngineDiagnostics.sampleGamepads()))
                #else
                throw CLIError("Native inspection requires macOS.")
                #endif
                return
            }
            let named = args.last == "--names"
            let command = named ? Array(args.dropLast()) : args
            guard args == ["preflight"] || command == ["midi","endpoints"] || command == ["gamepad","devices"] else {
                throw CLIError("Unknown command or flags. Use --help. Live output is not supported.")
            }
            #if os(macOS)
            if args == ["preflight"] {
                try emit(Envelope(command:"preflight",result:NativeEngineDiagnostics.preflight()))
            } else if command == ["gamepad","devices"] {
                try emit(Envelope(command:"gamepad devices",result:NativeEngineDiagnostics.gamepads(includeNames:named)))
            } else {
                try emit(Envelope(command:"midi endpoints",result:NativeEngineDiagnostics.midi(includeNames:named)))
            }
            #else
            throw CLIError("Native inspection requires macOS. Use the offline engine for portable analysis.")
            #endif
        } catch {
            let description=error is CancellationError ? "Session cancelled; no success report." :
                ((error as? LocalizedError)?.errorDescription ?? String(describing:error))
            FileHandle.standardError.write(Data(("tihulu-mac-instrument-native: " + description + "\n").utf8))
            exit(2)
        }
    }
}
