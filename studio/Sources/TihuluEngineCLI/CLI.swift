import Foundation
import NoSpeakerCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Offline shell interface to the same engine types used by Studio.
/// Never opens hardware, sends MIDI, requests permission or starts a service.
@main
struct TihuluEngineCLI {
    struct CLIError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    struct Frame: Decodable {
        let source: SensorSource
        let sequence: UInt64
        let time: Double
        let values: [String: Double]
        let releasing: [String]?
    }

    static func main() {
        do {
            let result = try run(Array(CommandLine.arguments.dropFirst()))
            let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data(("tihulu-engine: " + String(describing:error) + "\n").utf8))
            exit(2)
        }
    }

    static func read(_ path: String, limit: Int = WorkspaceArchive.maximumBytes) throws -> Data {
        let url = URL(fileURLWithPath:path)
        let info = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= limit else {
            throw CLIError("Expected a bounded regular input file")
        }
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount:limit+1) ?? Data()
        guard data.count <= limit else { throw CLIError("Input exceeds size limit") }
        return data
    }

    static func run(_ args: [String]) throws -> [String: Any] {
        if args == ["help"] || args == ["--help"] || args.isEmpty {
            return [
                "schema":1, "hardware":false,
                "commands":["capabilities","patch example","patch validate FILE","patch routes FILE",
                    "groups example","groups validate FILE","groups ports FILE",
                    "groups simulate PROFILE FRAMES [--allow-layering]"]
            ]
        }
        if args == ["capabilities"] {
            return ["schema":1,"hardware":false,"sources":SensorSource.allCases.map(\.rawValue),
                "signals":SensorSignal.allCases.map(\.rawValue),
                "maxGroups":PerformanceGroupProfile.maximumGroups,
                "maxRoutes":PerformanceGroupProfile.maximumRoutes,
                "maxSessions":PerformanceGroupRouter.maxSessions,
                "midiDelivery":"simulation only","mpePorts":"not implemented in CLI"]
        }
        if args == ["patch","example"] {
            let data = try InstrumentPatch.starter.archive()
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
                throw CLIError("Invalid example archive")
            }
            return object
        }
        if args == ["groups","example"] {
            let profile = PerformanceGroupProfile(groups:[.init(name:"Example",patch:.starter)])
            guard let object = try JSONSerialization.jsonObject(with:profile.archive()) as? [String:Any] else {
                throw CLIError("Invalid example profile")
            }
            return object
        }
        if args.count == 3, args[0] == "patch" {
            let patch = try InstrumentPatch.read(read(args[2]))
            switch args[1] {
            case "validate": return ["schema":1,"valid":true,"name":patch.name,"routes":patch.routes.count]
            case "routes":
                let rows: [[String:Any]] = DAWRoutingOverview.rows(for:patch).map {
                    ["channel":$0.channel+1,"notes":$0.noteSources.map(\.rawValue),
                     "controls":$0.controlSources.map(\.rawValue)]
                }
                return ["schema":1,"logicalOnly":true,"routes":rows]
            default: throw CLIError("Unknown patch command")
            }
        }
        if args.count == 3, args[0] == "groups" {
            let profile = try PerformanceGroupProfile.read(read(args[2]))
            switch args[1] {
            case "validate":
                return ["schema":1,"valid":true,"groups":profile.groups.count,
                        "layeredInputs":profile.layeredInputs.map(\.id)]
            case "ports":
                let plan = try PerformanceGroupEndpointPlan(profile:profile)
                let rows: [[String:Any]] = plan.entries.map {
                    ["groupID":$0.id.uuidString,"name":$0.portName,"uniqueID":Int($0.uniqueID)]
                }
                return ["schema":1,"registered":false,"ports":rows]
            default: throw CLIError("Unknown group command")
            }
        }
        if (args.count == 4 || (args.count == 5 && args[4] == "--allow-layering")),
           args[0] == "groups", args[1] == "simulate" {
            let profile = try PerformanceGroupProfile.read(read(args[2]))
            let frames = try JSONDecoder().decode([Frame].self,from:read(args[3]))
            return try simulate(profile,frames:frames,allowLayering:args.count == 5)
        }
        throw CLIError("Unknown command or arguments; use --help")
    }

    static func simulate(_ profile: PerformanceGroupProfile, frames: [Frame], allowLayering: Bool) throws -> [String:Any] {
        guard frames.count <= 4096 else { throw CLIError("Too many frames") }
        var delivery = try PerformanceGroupDelivery(profile:profile,allowLayering:allowLayering)
        var sessions: [SensorSource:UUID] = [:]
        var sequences: [SensorSource:UInt64] = [:]
        var lastTime = 0.0
        var events: [[String:Any]] = []
        for (index,frame) in frames.enumerated() {
            let stride = UInt64(SensorSignal.allCases.count+1)
            guard frame.time.isFinite,frame.time >= lastTime,
                  frame.sequence <= (UInt64.max-stride)/stride,
                  sequences[frame.source].map({ frame.sequence > $0 }) ?? true else {
                throw CLIError("Invalid frame time or sequence at index " + String(index))
            }
            var values: [SensorSignal:Double] = [:]
            for (key,value) in frame.values {
                guard let signal = SensorSignal(rawValue:key),value.isFinite,(0...1).contains(value) else {
                    throw CLIError("Invalid signal or value")
                }
                values[signal] = value
            }
            var releases: Set<SensorSignal> = []
            for key in frame.releasing ?? [] {
                guard let signal = SensorSignal(rawValue:key),values[signal] == nil,
                      releases.insert(signal).inserted else { throw CLIError("Invalid release") }
            }
            let lease: UUID
            if let existing = sessions[frame.source] { lease = existing }
            else {
                lease = try delivery.connect(frame.source,now:frame.time)
                sessions[frame.source] = lease
            }
            sequences[frame.source] = frame.sequence
            lastTime = frame.time
            _ = delivery.frame(lease:lease,sequence:frame.sequence,now:frame.time,values:values,releasing:releases) {
                events.append(event($0,index:index)); return true
            }
            guard events.count <= 65536 else { throw CLIError("Simulation output exceeds limit") }
        }
        _ = delivery.panic { events.append(event($0,index:frames.count)); return true }
        return ["schema":1,"simulated":true,"hardware":false,"frames":frames.count,
                "cleanupComplete":delivery.pendingCleanup.isEmpty,"events":events]
    }

    static func event(_ item: PerformanceGroupCommand,index: Int) -> [String:Any] {
        let d = item.command.destination
        return ["frame":index,"groupID":item.groupID.uuidString,"channel":d.channel+1,
                "kind":d.kind.rawValue,"number":d.number,"value":item.command.value]
    }
}
