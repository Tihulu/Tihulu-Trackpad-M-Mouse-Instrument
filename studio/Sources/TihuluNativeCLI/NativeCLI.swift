import Foundation
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
        let commands = ["capabilities","preflight","midi endpoints [--names]"]
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

    @MainActor
    static func main() {
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
            guard args == ["preflight"] || args == ["midi","endpoints"] || args == ["midi","endpoints","--names"] else {
                throw CLIError("Unknown command or flags. Use --help. Live output is not supported.")
            }
            #if os(macOS)
            if args == ["preflight"] {
                try emit(Envelope(command:"preflight",result:NativeEngineDiagnostics.preflight()))
            } else {
                try emit(Envelope(command:"midi endpoints",
                    result:NativeEngineDiagnostics.midi(includeNames:args.last == "--names")))
            }
            #else
            throw CLIError("Native inspection requires macOS. Use the offline engine for portable analysis.")
            #endif
        } catch {
            FileHandle.standardError.write(Data(("tihulu-mac-instrument-native: " + String(describing:error) + "\n").utf8))
            exit(2)
        }
    }
}
