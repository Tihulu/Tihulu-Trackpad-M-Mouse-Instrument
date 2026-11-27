import Foundation

/// Pure mixed standard-MIDI intent. Does not admit an endpoint, configure
/// pitch-bend range or send MIDI. The physical adapter must reconcile through
/// shared note, sustain and continuous owner ledgers and account for failed
/// sends. No tuned/MPE fallback, arbitrary switch CCs or implicit layering.
public struct CustomSurfaceMixedPlan: Sendable {
    public enum Failure:Error,Equatable {
        case channelConflict
        case unsupportedPad(String)
        case duplicateContinuousTarget(SensorDestination)
    }
    public struct Output:Equatable,Sendable {
        public let notes:CustomSurfaceStandardNotePlan.Notes
        public let sustainChannels:Set<Int>
        public let continuous:[SensorDestination:LegacyContinuousOwners.Value]
    }
    public let layout:CustomSurfacePadLayout
    public let melodicChannel:Int
    /// All possible destinations, including currently idle pads. An endpoint
    /// reservation must cover the entire frozen plan, not only active notes.
    public var destinations:Set<SensorDestination> {
        var result:Set<SensorDestination>=[]
        for pad in layout.pads {
            if let notes=CustomSurfaceStandardNotePlan.noteTargets(pad.assignment,melodicChannel:melodicChannel) {
                result.formUnion(notes)
            } else {
                switch pad.assignment {
                case .helper(let target):result.insert(target)
                case .xy(let x,let y):result.insert(x);result.insert(y)
                default:break
                }
            }
        }
        return result
    }

    /// Advisory only: independent source ports are valid even when wire
    /// destinations coincide. If a receiver merges them, channel-wide
    /// sustain, pitch bend and CC can affect the other source's notes.
    public struct RoutingOverlap: Equatable, Sendable {
        public let channels: Set<Int>
        public let destinations: Set<SensorDestination>
    }
    public func overlapIfMerged(with other: Self) -> RoutingOverlap {
        let a = destinations, b = other.destinations
        return .init(channels: Set(a.map(\.channel)).intersection(Set(b.map(\.channel))),
                     destinations: a.intersection(b))
    }

    public init(layout:CustomSurfacePadLayout,melodicChannel:Int)throws {
        guard CustomSurfaceStandardNotePlan(layout:layout,melodicChannel:melodicChannel) != nil else{throw Failure.channelConflict}
        var reserved:Set<SensorDestination>=[]
        for pad in layout.pads {
            let targets:[SensorDestination]
            switch pad.assignment {
            case .note,.chord,.drum:targets=[]
            case .degree:throw Failure.unsupportedPad(pad.id)
            case .helper(let target):
                targets=target.kind == .sustain ? []:[target]
            case .xy(let x,let y):targets=[x,y]
            }
            for target in targets {
                guard Self.continuous(target) else{throw Failure.unsupportedPad(pad.id)}
                guard reserved.insert(target).inserted else{throw Failure.duplicateContinuousTarget(target)}
            }
        }
        self.layout=layout;self.melodicChannel=melodicChannel
    }

    private static func continuous(_ target:SensorDestination)->Bool {
        target.isValid && (target.kind == .pitchBend ||
            (target.kind == .controlChange && HelperCCPolicy.permits(target.number) && !(64...69).contains(target.number)))
    }
    private static func value(_ target:SensorDestination,_ normalized:Double)->LegacyContinuousOwners.Value {
        if target.kind == .pitchBend {
            // Full 14-bit range; existing receiver bend sensitivity is not
            // changed or guessed by this plan.
            return .init(Int((normalized*16383).rounded()),neutral:8192)
        }
        return .init(Int((normalized*127).rounded()),neutral:[7,11].contains(target.number) ? 127:0)
    }

    public func output(for snapshot:CustomSurfaceContactProjection.Snapshot)->Output? {
        guard snapshot.layout==layout else{return nil}
        var notes:[Int:Set<SensorDestination>]=[:]
        var velocities:[Int:Int]=[:]
        var sustain:Set<Int>=[]
        var controls:[SensorDestination:LegacyContinuousOwners.Value]=[:]
        var contacts:Set<Int>=[]
        if !snapshot.retired {
            // Within one control pad, lowest stable contact ID wins. Note
            // and sustain contacts remain independent; no arrival ordering.
            for intent in snapshot.intents.sorted(by:{$0.contactID<$1.contactID}) {
                guard contacts.insert(intent.contactID).inserted,
                      (0...1).contains(intent.x),(0...1).contains(intent.y),
                      (1...127).contains(intent.velocity),
                      let pad=layout.pads.first(where:{$0.id==intent.padID}),
                      pad.assignment==intent.assignment else{return nil}
                if let targets=CustomSurfaceStandardNotePlan.noteTargets(pad.assignment,melodicChannel:melodicChannel) {
                    notes[intent.contactID]=targets;velocities[intent.contactID]=intent.velocity
                    continue
                }
                switch pad.assignment {
                case .helper(let target):
                    if target.kind == .sustain {sustain.insert(target.channel)}
                    else if controls[target]==nil {controls[target]=Self.value(target,intent.x)}
                case .xy(let x,let y):
                    if controls[x]==nil {controls[x]=Self.value(x,intent.x);controls[y]=Self.value(y,intent.y)}
                default:return nil
                }
            }
        }
        return .init(notes:.init(desired:notes,velocities:velocities),sustainChannels:sustain,continuous:controls)
    }
}
