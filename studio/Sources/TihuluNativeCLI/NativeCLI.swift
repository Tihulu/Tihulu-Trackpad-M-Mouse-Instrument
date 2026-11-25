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
        let commands = ["capabilities","preflight","midi endpoints [--names]","gamepad devices [--names]","gamepad sample --confirm","midi monitor NAME SECONDS --confirm","session probe SECONDS --confirm","midi plan JSON"]
    }
    struct Envelope<Payload:Encodable>: Encodable {
        let schema = 1
        let liveOutput = false
        let command:String
        let result:Payload
    }
    static func emit<T:Encodable>(_ payload:T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data([10]))
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
        let clip=try BoundedMIDIPlanInput.decode(Data(json.utf8))
        let player=try BoundedMIDIPlayback(clip:clip)
        var active=0,peak=0
        for event in player.events {
            active += event.command.value>0 ? 1 : -1
            peak=max(peak,active)
        }
        return .init(noteCount:clip.notes.count,eventCount:player.events.count,
                     durationNS:player.durationNS,peakConcurrentNotes:peak)
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
    static func withProcessStop<T:Sendable>(_ operation:@escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        guard tihulu_stop_install()==0 else { throw CLIError("Could not install process stop handlers.") }
        defer { tihulu_stop_restore() }
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
        guard tihulu_stop_requested()==0 else { throw CancellationError() }
        return value
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
            if args.count>=2 && Array(args.prefix(2)) == ["session","probe"] {
                guard args.count==4,args[3]=="--confirm",let seconds=Int(args[2]),
                      String(seconds)==args[2],(1...10).contains(seconds) else {
                    throw CLIError("Use session probe SECONDS --confirm (1-10 seconds).")
                }
                let result=try await withProcessStop {
                    // Readiness is diagnostic stderr only. JSON is emitted
                    // after successful completion, never on cancellation.
                    FileHandle.standardError.write(Data("session probe ready\n".utf8))
                    defer { FileHandle.standardError.write(Data("session probe cleanup\n".utf8)) }
                    try await Task.sleep(nanoseconds:UInt64(seconds)*1_000_000_000)
                    return SessionProbe(requestedSeconds:seconds,completed:true)
                }
                try emit(Envelope(command:"session probe",result:result))
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
                let result=try await withProcessStop {
                    try await NativeMIDIMonitor.observe(sourceName:args[2],seconds:seconds)
                }
                try emit(Envelope(command:"midi monitor",result:result))
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
