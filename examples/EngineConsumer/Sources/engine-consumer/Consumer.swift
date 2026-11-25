import Foundation
import NoSpeakerCore

// External package example. No dependency on Studio, native devices, or MIDI.
@main
struct Consumer {
    static func main() throws {
        let patch = InstrumentPatch(name:"External controller",routes:[
            .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
            .init(id:"pedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain))
        ])
        let group = PerformanceInstrumentGroup(name:"External piano",patch:patch)
        let profile = PerformanceGroupProfile(groups:[group])
        var engine = try PerformanceGroupDelivery(profile:profile)
        let notes = try engine.connect(.trackpad,now:1)
        let pedal = try engine.connect(.gamepad1,now:1)
        var commands: [PerformanceGroupCommand] = []
        _ = engine.frame(lease:notes,sequence:1,now:1,values:[.contact:1]) {
            commands.append($0); return true
        }
        _ = engine.frame(lease:pedal,sequence:1,now:1.1,values:[.padRT:1]) {
            commands.append($0); return true
        }
        _ = engine.panic { commands.append($0); return true }
        guard commands.count == 4, engine.pendingCleanup.isEmpty,
              commands.allSatisfy({ $0.groupID == group.id }),
              commands.filter({ $0.command.destination.kind == .note }).map({ $0.command.value }) == [100,0],
              commands.filter({ $0.command.destination.kind == .sustain }).map({ $0.command.value }) == [127,0]
        else { throw ExampleError.unexpectedCommands }
        print("External engine consumer: note and sustain isolation passed; no hardware.")
    }
    enum ExampleError: Error { case unexpectedCommands }
}
