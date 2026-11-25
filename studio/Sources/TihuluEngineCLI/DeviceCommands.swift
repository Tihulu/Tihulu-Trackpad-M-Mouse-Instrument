import Foundation
import NoSpeakerCore

extension TihuluEngineCLI {
    private struct GamepadInput: Decodable {
        let buttons: [Double]
        let triggers: [Double]
        let sticks: [Double]
    }

    private struct CameraInput: Decodable {
        struct Hand: Decodable {
            let x: Double
            let y: Double
            let aperture: Double

            func sample() throws -> AirHandSample {
                guard let value = AirHandSample.debugSample(x:x,y:y,aperture:aperture) else {
                    throw CLIError("Invalid normalized hand sample")
                }
                return value
            }
        }
        let time: Double
        let now: Double
        let left: Hand?
        let right: Hand?
    }

    /// Offline device policy helpers. Raw OS device access is intentionally
    /// outside this CLI. Reuse the production normalization and replay engines.
    static func deviceCommand(_ args: [String]) throws -> [String:Any]? {
        if args.count == 3, args[0] == "gamepad", args[1] == "normalize" {
            let data = try read(args[2])
            guard let shape = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  Set(shape.keys) == ["buttons","triggers","sticks"] else {
                throw CLIError("Unsupported gamepad snapshot fields")
            }
            let input = try JSONDecoder().decode(GamepadInput.self,from:data)
            guard let frame = GamepadFrame(buttons:input.buttons,triggers:input.triggers,sticks:input.sticks) else {
                throw CLIError("Invalid full gamepad snapshot")
            }
            let values = Dictionary(uniqueKeysWithValues:frame.active.map { ($0.key.rawValue,$0.value) })
            return ["schema":1,"hardware":false,"snapshot":true,"values":values,
                    "releasing":GamepadFrame.signals.filter { frame.active[$0] == nil }.map(\.rawValue),
                    "buttonOrder":GamepadFrame.buttons.map(\.rawValue),
                    "triggerOrder":GamepadFrame.triggers.map(\.rawValue),
                    "stickOrder":GamepadFrame.sticks.map(\.rawValue)]
        }
        if args.count == 5, args[0] == "gamepad", args[1] == "patch" {
            guard let slot = Int(args[2]), (1...GamepadFrame.orderedSources.count).contains(slot),
                  let role = GamepadFrame.Role(rawValue:args[3]),
                  let channel = Int(args[4]), (1...16).contains(channel) else {
                throw CLIError("Expected controller slot 1-4, role drums/lead/helper and channel 1-16")
            }
            let patch = InstrumentPatch(name:"Controller " + String(slot) + " " + role.rawValue,
                routes:role.routes(source:GamepadFrame.orderedSources[slot-1],channel:channel-1))
            return try patchObject(patch)
        }
        if args.count == 4, args[0] == "camera", args[1] == "helper-patch" {
            guard let preset = AirHandsHelper.Preset(rawValue:args[2]),
                  let channel = Int(args[3]), (1...16).contains(channel) else {
                throw CLIError("Expected camera preset expressive/guitarEffects/pedalPair and channel 1-16")
            }
            return try patchObject(.init(name:"Camera " + preset.rawValue,
                                         routes:preset.routes(channel:channel-1)))
        }
        if args.count == 4, args[0] == "camera", args[1] == "helper-simulate" {
            let patch = try InstrumentPatch.read(read(args[2]))
            guard !patch.routes.isEmpty, patch.routes.allSatisfy({
                $0.source == .camera && AirHandsHelper.allSignals.contains($0.signal)
            }) else {
                throw CLIError("Expected a camera Helper-only patch")
            }
            let data = try read(args[3])
            guard let rows = try JSONSerialization.jsonObject(with:data) as? [[String:Any]],
                  (1...4096).contains(rows.count),
                  rows.allSatisfy({ row in
                      guard Set(row.keys).isSubset(of:["time","now","left","right"]) else { return false }
                      return ["left","right"].allSatisfy { key in
                          guard let hand = row[key], !(hand is NSNull) else { return true }
                          guard let fields = hand as? [String:Any] else { return false }
                          return Set(fields.keys) == ["x","y","aperture"]
                      }
                  }) else { throw CLIError("Invalid camera replay shape") }
            let frames = try JSONDecoder().decode([CameraInput].self,from:data)
            var simulation = PatchSimulation()
            try simulation.start(patch,now:0)
            guard simulation.hasHelperHands, !simulation.hasDualCamera else {
                throw CLIError("Unsupported camera replay patch")
            }
            var events: [[String:Any]] = []
            var previousNow = 0.0
            func row(_ command: SensorCommand,_ index: Int) -> [String:Any] {
                let d = command.destination
                return ["frame":index,"channel":d.channel+1,"kind":d.kind.rawValue,
                        "number":d.number,"value":command.value]
            }
            for (index,input) in frames.enumerated() {
                guard input.time.isFinite,input.now.isFinite,input.time >= 0,
                      input.now >= input.time,input.now >= previousNow else {
                    throw CLIError("Invalid camera replay time")
                }
                previousNow = input.now
                let left = try input.left?.sample()
                let right = try input.right?.sample()
                // Stale/late frames intentionally reach the production gate
                // so developers can test loss and neutral reacquisition.
                events += simulation.receiveHelperHands(left:left,right:right,time:input.time,now:input.now)
                    .map { row($0,index) }
                guard events.count <= 65536 else { throw CLIError("Camera output exceeds limit") }
            }
            events += simulation.stop().map { row($0,frames.count) }
            return ["schema":1,"hardware":false,"simulated":true,"events":events]
        }
        return nil
    }

    private static func patchObject(_ patch: InstrumentPatch) throws -> [String:Any] {
        guard !patch.routes.isEmpty,
              let result = try JSONSerialization.jsonObject(with:patch.archive()) as? [String:Any] else {
            throw CLIError("Invalid generated patch")
        }
        return result
    }
}
