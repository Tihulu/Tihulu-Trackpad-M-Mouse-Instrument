import Foundation

/// Standard MIDI note projection only. Unsupported tuned/control pads
/// remain explicitly identified rather than being rounded or dropped by
/// an implicit activation path. Callers must decide how to route them.
public struct CustomSurfaceStandardNotePlan: Sendable {
    public let layout:CustomSurfacePadLayout
    public let melodicChannel:Int
    public let unsupportedPadIDs:Set<String>
    public var isComplete:Bool {unsupportedPadIDs.isEmpty}
    public init?(layout:CustomSurfacePadLayout,melodicChannel:Int) {
        guard (0...15).contains(melodicChannel) else{return nil}
        let hasDrums=layout.pads.contains{if case .drum=$0.assignment {return true};return false}
        let hasMelody=layout.pads.contains{switch $0.assignment {case .note,.chord:return true;default:return false}}
        // Do not silently change the selected melodic channel.
        guard !(hasDrums && hasMelody && melodicChannel==GMDrumPads.midiChannel) else{return nil}
        self.layout=layout;self.melodicChannel=melodicChannel
        unsupportedPadIDs=Set(layout.pads.compactMap{pad in
            switch pad.assignment {case .note,.chord,.drum:return nil;default:return pad.id}
        })
    }
    public struct Notes:Sendable,Equatable {
        public let desired:[Int:Set<SensorDestination>]
        public let velocities:[Int:Int]
    }
    /// Only an entire supported layout can use this standard-note plan.
    /// No partial live activation, fallback to 12-TET or MIDI transmission.
    public func notes(for snapshot:CustomSurfaceContactProjection.Snapshot)->Notes? {
        guard isComplete,snapshot.layout==layout else{return nil}
        if snapshot.retired {return .init(desired:[:],velocities:[:])}
        var desired:[Int:Set<SensorDestination>]=[:]
        var velocities:[Int:Int]=[:]
        for intent in snapshot.intents {
            guard desired[intent.contactID]==nil,(1...127).contains(intent.velocity),
                  let pad=layout.pads.first(where:{$0.id==intent.padID}),pad.assignment==intent.assignment else{return nil}
            let targets:[SensorDestination]
            switch pad.assignment {
            case .note(let note):targets=[.init(.note,channel:melodicChannel,number:note)]
            case .chord(let notes):targets=notes.map{.init(.note,channel:melodicChannel,number:$0)}
            case .drum(let note):targets=[.init(.note,channel:GMDrumPads.midiChannel,number:note)]
            default:return nil
            }
            desired[intent.contactID]=Set(targets)
            velocities[intent.contactID]=intent.velocity
        }
        return .init(desired:desired,velocities:velocities)
    }
}
