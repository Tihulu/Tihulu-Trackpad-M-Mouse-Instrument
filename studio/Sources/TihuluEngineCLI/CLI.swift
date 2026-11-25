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

    struct MixInput: Decodable {
        let source: String
        let frame: HapticFrame
        let priority: Int?
        let exclusive: Bool?
    }

    struct NoteGrid: Decodable {
        struct Step: Decodable {
            let index: Int
            let midi: Int?
            let velocity: Double
            let gate: Double
        }
        let bpm: Double
        let stepsPerBeat: Int
        let length: Int
        let channel: Int
        let steps: [Step]
    }

    struct DrumGrid: Decodable {
        struct Hit: Decodable {
            let index: Int
            let voice: DrumVoice
            let velocity: Double
        }
        let bpm: Double
        let stepsPerBeat: Int
        let length: Int
        let hits: [Hit]
    }

    struct PedalInput: Decodable {
        let owner: String
        let channels: [Int]
    }

    struct HelperStep: Decodable {
        struct Control: Decodable {
            let target: SensorDestination
            let value: Int
            let neutral: Int
            let bendRange: Int?
            let preserveOnRelease: Bool?
        }
        let owner: String
        let controls: [Control]
    }

    struct TunedInput: Decodable {
        let clip: MIDIClip
        let root: Int
        let degreeCents: String
    }

    struct GrooveInput: Decodable {
        let clip: MIDIClip
        let groove: GrooveSettings
    }

    struct VoiceInput: Decodable {
        let sampleRate: Int
        let samples: [Float]
    }

    static func main() {
        do {
            let result = try run(Array(CommandLine.arguments.dropFirst()))
            let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data(("tihulu-mac-instrument-engine: " + String(describing:error) + "\n").utf8))
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

    // Reject fields that a nominal SMF exporter would otherwise silently
    // discard, such as tuning, per-note bend, or unsupported timing data.
    static func requireMIDIShape(_ data: Data, fields: Set<String>,
                                 list: String, rowFields: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == fields,
              let rows = object[list] as? [[String:Any]],
              rows.allSatisfy({ Set($0.keys).isSubset(of:rowFields) }) else {
            throw CLIError("Unsupported MIDI input fields or shape")
        }
    }

    @discardableResult
    static func requireClipEnvelope(_ data: Data, fields: Set<String>) throws -> [String:Any] {
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == fields,
              let clip = object["clip"] as? [String:Any] else {
            throw CLIError("Unsupported clip envelope")
        }
        try requireMIDIShape(JSONSerialization.data(withJSONObject:clip),
            fields:["bpm","length","notes"],list:"notes",
            rowFields:["start","duration","channel","pitch","velocity"])
        return object
    }

    static func run(_ args: [String]) throws -> [String: Any] {
        if args == ["help"] || args == ["--help"] || args.isEmpty {
            return [
                "schema":1, "hardware":false,
                "commands":["capabilities","patch example","patch validate FILE","patch routes FILE",
                    "groups example","groups validate FILE","groups ports FILE",
                    "groups simulate PROFILE FRAMES [--allow-layering]", "scale plan ROOT CENTS", "haptics mix FILE", "midi encode FILE", "midi melody FILE", "midi drums FILE", "sustain simulate FILE", "helper simulate FILE", "midi tuned FILE", "midi groove FILE", "voice analyze FILE", "gamepad normalize FILE", "gamepad patch SLOT ROLE CHANNEL", "camera helper-patch PRESET CHANNEL", "camera helper-simulate PATCH FRAMES"]
            ]
        }
        if args == ["capabilities"] {
            return ["schema":1,"hardware":false,"sources":SensorSource.allCases.map(\.rawValue),
                "signals":SensorSignal.allCases.map(\.rawValue),
                "maxGroups":PerformanceGroupProfile.maximumGroups,
                "maxRoutes":PerformanceGroupProfile.maximumRoutes,
                "maxSessions":PerformanceGroupRouter.maxSessions,
                "midiDelivery":"simulation only","mpePorts":"not implemented in CLI",
                "scalePlanning":true,"hapticMixPreview":true,"standardMIDIFileExport":true,"sustainSimulation":true,"helperOwnershipSimulation":true,"tunedMIDIFileExport":true,"grooveExport":true,"voiceAnalysisPreview":true,"gamepadSnapshotNormalization":true,"cameraHelperReplay":true]
        }
        if let device = try deviceCommand(args) { return device }
        if args.count == 4, args[0] == "scale", args[1] == "plan" {
            guard let root = Int(args[2]), (0...115).contains(root),
                  let scale = CustomScale.fromDegreeCents(args[3],name:"CLI scale") else {
                throw CLIError("Invalid root or unsupported degree cents")
            }
            let rows: [[String:Any]] = try scale.intervals.map { degree in
                let note = root + degree
                guard let pitch = scale.mpePitch(midi:note,root:root),
                      let hz = scale.tunedFrequency(midi:note,root:root) else {
                    throw CLIError("Invalid tuned pitch")
                }
                return ["note":pitch.anchor,"bend":pitch.bend,"bendRange":pitch.bendRange,
                        "frequencyHz":hz,"degreeCents":degree*100+(scale.centOffsets[degree] ?? 0)]
            }
            return ["schema":1,"planned":true,"hardware":false,"microtonal":scale.isMicrotonal,"pitches":rows]
        }
        if args.count == 3, args[0] == "haptics", args[1] == "mix" {
            let inputs = try JSONDecoder().decode([MixInput].self,from:read(args[2]))
            guard (1...HapticMixSource.allCases.count).contains(inputs.count) else {
                throw CLIError("Invalid haptic source count")
            }
            var mixer = HapticFrameMixer()
            var seen: Set<HapticMixSource> = []
            for input in inputs {
                let priority = input.priority ?? 0
                guard let source = HapticMixSource(rawValue:input.source),
                      seen.insert(source).inserted, (-100...100).contains(priority) else {
                    throw CLIError("Invalid or repeated haptic source")
                }
                let lease = mixer.begin(source,priority:priority,mode:input.exclusive == true ? .exclusive : .continuous)
                guard mixer.submit(input.frame,from:lease,now:0) else {
                    throw CLIError("Invalid haptic frame")
                }
            }
            let frame: Any
            if let mixed = mixer.render(now:0) {
                frame = try JSONSerialization.jsonObject(with:JSONEncoder().encode(mixed))
            } else {
                frame = NSNull()
            }
            return ["schema":1,"simulated":true,"hardware":false,"frame":frame]
        }
        if args.count == 3, args[0] == "midi", args[1] == "tuned" {
            let data = try read(args[2])
            try requireClipEnvelope(data,fields:["clip","root","degreeCents"])
            let input = try JSONDecoder().decode(TunedInput.self,from:data)
            guard let scale = CustomScale.fromDegreeCents(input.degreeCents,name:"CLI tuning"),
                  !input.clip.notes.contains(where:{ $0.channel == 9 }) else {
                throw CLIError("Invalid tuning or percussion channel in melodic MPE export")
            }
            let tuned = try TunedMIDIClip(input.clip,scale:scale,root:input.root)
            let midi = tuned.encoded()
            let members: [[String:Any]] = tuned.members.map {
                ["channel":$0.channel+1,"bend":$0.bend]
            }
            return ["schema":1,"hardware":false,"encoding":"base64","format":"SMF0",
                    "nominalPitchesOnly":false,"mpeRequired":true,"masterChannel":1,
                    "bendRange":2,"members":members,"ppq":MIDIClip.ppq,
                    "notes":tuned.clip.notes.count,"bytes":midi.count,"data":midi.base64EncodedString()]
        }
        if args.count == 3, args[0] == "midi", args[1] == "groove" {
            let data = try read(args[2])
            let envelope = try requireClipEnvelope(data,fields:["clip","groove"])
            guard let groove = envelope["groove"] as? [String:Any],
                  Set(groove.keys) == ["swing","humanize","intensity","accent","probability","seed"] else {
                throw CLIError("Unsupported groove fields")
            }
            let input = try JSONDecoder().decode(GrooveInput.self,from:data)
            let clip = try input.groove.apply(to:input.clip)
            let midi = try MIDIClipWriter.encode(clip)
            let symbolic = try JSONSerialization.jsonObject(with:JSONEncoder().encode(clip))
            return ["schema":1,"hardware":false,"encoding":"base64","format":"SMF0",
                    "nominalPitchesOnly":true,"ppq":MIDIClip.ppq,"clip":symbolic,
                    "notes":clip.notes.count,"bytes":midi.count,"data":midi.base64EncodedString()]
        }
        if args.count == 3, args[0] == "voice", args[1] == "analyze" {
            let data = try read(args[2])
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  Set(object.keys) == ["sampleRate","samples"] else {
                throw CLIError("Unsupported voice analysis fields")
            }
            let input = try JSONDecoder().decode(VoiceInput.self,from:data)
            guard input.sampleRate == Int(HapticVoiceAnalyzer.sampleRate),
                  (400...80000).contains(input.samples.count),
                  input.samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw CLIError("Expected 25 ms to 5 s of normalized mono PCM at 16000 Hz")
            }
            let frames = try HapticVoiceAnalyzer.analyze(input.samples,cancellation:.init())
            guard frames.allSatisfy({ $0.formants.count == 3 && $0.amplitudes.count == 3 &&
                $0.formants.allSatisfy(\.isFinite) && $0.amplitudes.allSatisfy(\.isFinite) &&
                $0.level.isFinite && $0.fundamentalHz.isFinite }) else {
                throw CLIError("Nonfinite voice analysis result")
            }
            let events = HapticVoiceAnalyzer.hapticEvents(frames:frames)
            let result = try JSONSerialization.jsonObject(with:JSONEncoder().encode(events))
            return ["schema":1,"hardware":false,"analysisOnly":true,"sampleRate":input.sampleRate,
                    "hopSeconds":HapticVoiceAnalyzer.hopSeconds,"frames":frames.count,"events":result]
        }
        if args.count == 3, args[0] == "midi" {
            let data = try read(args[2])
            let clip: MIDIClip
            switch args[1] {
            case "encode":
                try requireMIDIShape(data,fields:["bpm","length","notes"],list:"notes",
                    rowFields:["start","duration","channel","pitch","velocity"])
                clip = try JSONDecoder().decode(MIDIClip.self,from:data).validated()
            case "melody":
                try requireMIDIShape(data,fields:["bpm","stepsPerBeat","length","channel","steps"],list:"steps",
                    rowFields:["index","midi","velocity","gate"])
                let grid = try JSONDecoder().decode(NoteGrid.self,from:data)
                guard (0...15).contains(grid.channel), grid.steps.count <= 4096,
                      grid.steps.allSatisfy({ (0..<max(0,grid.length)).contains($0.index) &&
                          $0.velocity.isFinite && (0...1).contains($0.velocity) &&
                          $0.gate.isFinite && (0.05...1).contains($0.gate) &&
                          ($0.midi.map { (0...127).contains($0) } ?? true) }),
                      Set(grid.steps.map(\.index)).count == grid.steps.count else {
                    throw CLIError("Invalid or repeated note grid step")
                }
                let sequence = NoteSequence(bpm:grid.bpm,stepsPerBeat:grid.stepsPerBeat,length:grid.length,
                    steps:grid.steps.map { .init(index:$0.index,midi:$0.midi,velocity:$0.velocity,gate:$0.gate) })
                clip = try MIDIClip.melody(sequence,channel:grid.channel)
            case "drums":
                try requireMIDIShape(data,fields:["bpm","stepsPerBeat","length","hits"],list:"hits",
                    rowFields:["index","voice","velocity"])
                let grid = try JSONDecoder().decode(DrumGrid.self,from:data)
                let sequence = DrumSequence(bpm:grid.bpm,stepsPerBeat:grid.stepsPerBeat,length:grid.length,
                    hits:grid.hits.map { .init(index:$0.index,voice:$0.voice,velocity:$0.velocity) })
                clip = try MIDIClip.drums(sequence)
            default: throw CLIError("Unknown MIDI file command")
            }
            let midi = try MIDIClipWriter.encode(clip)
            return ["schema":1,"hardware":false,"encoding":"base64","format":"SMF0",
                    "nominalPitchesOnly":true,"ppq":MIDIClip.ppq,"notes":clip.notes.count,
                    "bytes":midi.count,"data":midi.base64EncodedString()]
        }
        if args.count == 3, args[0] == "sustain", args[1] == "simulate" {
            let steps = try JSONDecoder().decode([PedalInput].self,from:read(args[2]))
            guard steps.count <= 4096 else { throw CLIError("Too many pedal steps") }
            var owners = LegacySustainOwners()
            var events: [[String:Any]] = []
            for (index,step) in steps.enumerated() {
                let owner: LegacySustainOwners.Owner
                switch step.owner {
                case "touch": owner = .touch
                case "helper": owner = .helper
                case "touchBar": owner = .touchBar
                default: throw CLIError("Unknown sustain owner")
                }
                let channels = Set(step.channels)
                guard channels.count == step.channels.count,
                      channels.allSatisfy({ (0...15).contains($0) }) else {
                    throw CLIError("Invalid or repeated sustain channel")
                }
                events += owners.replace(owner,channels:channels).map {
                    ["step":index,"channel":$0.destination.channel+1,"cc":64,"value":$0.value]
                }
            }
            events += owners.releaseAll().map {
                ["step":steps.count,"channel":$0.destination.channel+1,"cc":64,"value":$0.value]
            }
            return ["schema":1,"simulated":true,"hardware":false,"events":events]
        }
        if args.count == 3, args[0] == "helper", args[1] == "simulate" {
            let steps = try JSONDecoder().decode([HelperStep].self,from:read(args[2]))
            guard steps.count <= 4096 else { throw CLIError("Too many Helper steps") }
            var owners = LegacyContinuousOwners()
            var events: [[String:Any]] = []
            for (index,step) in steps.enumerated() {
                let owner: LegacyContinuousOwners.Owner
                switch step.owner {
                case "touch": owner = .touch
                case "legacyTouch": owner = .legacyTouch
                case "helper": owner = .helper
                case "touchBar": owner = .touchBar
                default: throw CLIError("Unknown Helper owner")
                }
                guard step.controls.count <= SensorRouter.maxMappings else {
                    throw CLIError("Too many continuous targets")
                }
                var desired: [SensorDestination:LegacyContinuousOwners.Value] = [:]
                for control in step.controls {
                    guard desired[control.target] == nil else { throw CLIError("Repeated Helper target") }
                    desired[control.target] = .init(control.value,neutral:control.neutral,
                        bendRange:control.bendRange,preserveOnRelease:control.preserveOnRelease ?? false)
                }
                // Production ownership validates the complete snapshot before
                // changing it. Check its postcondition to distinguish invalid
                // input from valid no-op and hidden lower-priority updates.
                let updates = owners.replace(owner,values:desired)
                guard owners.values(for:owner) == desired else {
                    throw CLIError("Invalid Helper snapshot")
                }
                events += updates.map { helperEvent($0,step:index) }
                guard events.count <= 65536 else { throw CLIError("Helper output exceeds limit") }
            }
            events += owners.releaseAll().map { helperEvent($0,step:steps.count) }
            return ["schema":1,"simulated":true,"hardware":false,"events":events]
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

    static func helperEvent(_ item: LegacyContinuousOwners.Update,step: Int) -> [String:Any] {
        var row: [String:Any] = ["step":step,"channel":item.target.channel+1,
            "kind":item.target.kind.rawValue,"number":item.target.number,"value":item.value,
            "neutral":item.neutral,"preserveOnRelease":item.preserveOnRelease]
        if let range = item.bendRange { row["bendRange"] = range }
        return row
    }

    static func event(_ item: PerformanceGroupCommand,index: Int) -> [String:Any] {
        let d = item.command.destination
        return ["frame":index,"groupID":item.groupID.uuidString,"channel":d.channel+1,
                "kind":d.kind.rawValue,"number":d.number,"value":item.command.value]
    }
}
