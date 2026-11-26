import Foundation

/// Frozen, source-local projection of complete physical contact snapshots.
/// The adapter must supply actual down contacts, stable IDs, top-left
/// coordinates and the original monotonic receipt. This is logical intent,
/// not a MIDI sender, hardware admission or delivery acknowledgement.
public struct CustomSurfaceContactProjection: Sendable {
    public struct Contact: Equatable, Sendable {
        public let id: Int
        public let x: Double
        public let y: Double
        public let velocity: Int
        public init(id:Int,x:Double,y:Double,velocity:Int=100) {
            self.id=id;self.x=x;self.y=y;self.velocity=velocity
        }
        fileprivate var valid:Bool {
            id>=0 && (0...1).contains(x) && (0...1).contains(y) && (1...127).contains(velocity)
        }
    }
    public struct Intent: Equatable, Sendable {
        public let contactID:Int
        public let padID:String
        public let assignment:CustomSurfacePadLayout.Assignment
        public let x:Double
        /// Local Y increases upward, as for the existing physical mappings.
        public let y:Double
        public let velocity:Int
    }
    public struct Snapshot: Equatable, Sendable {
        public let intents:[Intent]
        public let retired:Bool
    }
    private struct Binding: Sendable {
        var pad:CustomSurfacePadLayout.Pad?
        let velocity:Int
    }
    public let layout:CustomSurfacePadLayout
    public private(set) var retired=false
    public static let maximumContacts=64
    private var down:[Int:Binding]=[:]
    private var lastSequence:UInt64?
    private var lastObservation:Int64?
    private var lastReceipt:Int64?
    private var lastIntent:[Intent]=[]
    public init(layout:CustomSurfacePadLayout) {self.layout=layout}
    /// Initial neutral snapshot required; no note from a finger already
    /// down when a source is first armed.
    private var neutralSeen=false

    public mutating func frame(_ contacts:[Contact],sequence:UInt64,observedAt:Int64,now:Int64)->Snapshot {
        guard !retired, now>=0,observedAt>=0,observedAt<=now,
              now-observedAt<MobileAirSendGate.freshNS,
              lastReceipt.map({now >= $0}) ?? true,
              lastSequence.map({sequence > $0}) ?? true,
              lastObservation.map({observedAt > $0 && now-$0<MobileAirSendGate.freshNS}) ?? true,
              contacts.count<=Self.maximumContacts,contacts.allSatisfy(\.valid),
              Set(contacts.map(\.id)).count==contacts.count else{return retire()}
        lastReceipt=now;lastObservation=observedAt;lastSequence=sequence
        if !neutralSeen {
            neutralSeen=contacts.isEmpty
            return .init(intents:[],retired:false)
        }
        var next:[Int:Binding]=[:]
        var intents:[Intent]=[]
        for contact in contacts.sorted(by:{$0.id<$1.id}) {
            var binding=down[contact.id] ?? Binding(pad:layout.pad(x:contact.x,y:contact.y),velocity:contact.velocity)
            if let pad=binding.pad {
                let inside=layout.pad(x:contact.x,y:contact.y)?.id==pad.id
                // A continuous helper/XY or sustain releases on leaving
                // its region; the same contact cannot acquire another pad.
                switch pad.assignment {
                case .helper,.xy:
                    if !inside {binding.pad=nil}
                default:break
                }
                if binding.pad != nil {
                    let x=min(1,max(0,(contact.x-Double(pad.x)/10000)/(Double(pad.width)/10000)))
                    let y=1-min(1,max(0,(contact.y-Double(pad.y)/10000)/(Double(pad.height)/10000)))
                    intents.append(.init(contactID:contact.id,padID:pad.id,assignment:pad.assignment,x:x,y:y,velocity:binding.velocity))
                }
            }
            next[contact.id]=binding
        }
        down=next;lastIntent=intents
        return .init(intents:intents,retired:false)
    }

    /// Independent watchdog. An expired or regressed clock retires the
    /// source permanently; callers must release its owners and explicitly
    /// create a fresh projection after neutral.
    public mutating func poll(now:Int64)->Snapshot {
        guard !retired,now>=0,lastReceipt.map({now >= $0}) ?? true,
              lastObservation.map({now-$0<MobileAirSendGate.freshNS}) ?? true else{return retire()}
        lastReceipt=now
        return .init(intents:lastIntent,retired:false)
    }
    public mutating func retire()->Snapshot {
        retired=true;down.removeAll();lastIntent=[]
        return .init(intents:[],retired:true)
    }
}
