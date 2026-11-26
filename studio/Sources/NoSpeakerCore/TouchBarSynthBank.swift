import Foundation

/// Custom 7-bit MIDI control descriptions, not plugin parameter discovery.
/// Uses the existing continuous owner policy; dedicated selectors, pedals,
/// and built-in Touch Bar targets must not be duplicated in this bank.
public struct TouchBarSynthBank: Codable, Equatable, Sendable {
    public enum Style:String,Codable,CaseIterable,Identifiable,Sendable {
        case knob="Knob",slider="Slider",toggle="Toggle"
        public var id:String{rawValue}
    }
    public enum Curve:String,Codable,CaseIterable,Identifiable,Sendable {
        case linear="Linear",fineLow="Fine at low end",fineHigh="Fine at high end"
        public var id:String{rawValue}
        fileprivate func apply(_ x:Double)->Double {
            switch self {case .linear:x;case .fineLow:x*x;case .fineHigh:1-(1-x)*(1-x)}
        }
        fileprivate func inverse(_ x:Double)->Double {
            switch self {case .linear:x;case .fineLow:x.squareRoot();case .fineHigh:1-(1-x).squareRoot()}
        }
    }
    public struct Control:Codable,Equatable,Sendable,Identifiable {
        public let id:UUID
        public let name:String
        public let cc:Int
        public let style:Style
        public let low:Int
        public let high:Int
        public let neutral:Int
        /// Nil retains the profile channel and old saved settings.
        public let channel:Int?
        public let inverted:Bool?
        public let curve:Curve?
        public init(id:UUID=UUID(),name:String,cc:Int,style:Style = .knob,low:Int=0,high:Int=127,neutral:Int=0,channel:Int?=nil,inverted:Bool?=nil,curve:Curve?=nil){
            self.id=id;self.name=name;self.cc=cc;self.style=style
            self.low=low;self.high=high;self.neutral=neutral
            self.channel=channel;self.inverted=inverted;self.curve=curve
        }
        public var isValid:Bool {
            !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
            name.utf8.count<=64 && !name.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)} &&
            TouchBarSynthBank.permitsCC(cc) && (0...127).contains(low) &&
            (low...127).contains(high) && low<high && (0...127).contains(neutral) &&
            (channel.map{(0...15).contains($0)} ?? true)
        }
        public func value(normalized:Double)->Int? {
            guard isValid,normalized.isFinite,(0...1).contains(normalized) else{return nil}
            let x=inverted==true ? 1-normalized:normalized
            if style == .toggle {return x>=0.5 ? high:low}
            return low+Int((Double(high-low)*(curve ?? .linear).apply(x)).rounded())
        }
        public func destination(profileChannel:Int)->SensorDestination? {
            let resolved=channel ?? profileChannel
            guard isValid,(0...15).contains(resolved) else{return nil}
            return .init(.controlChange,channel:resolved,number:cc)
        }
        public var initialPosition:Double {
            guard isValid else{return 0}
            let fraction=min(1,max(0,Double(neutral-low)/Double(high-low)))
            let position=style == .toggle ? (fraction>=0.5 ? 1.0:0.0):(curve ?? .linear).inverse(fraction)
            return inverted==true ? 1-position:position
        }
    }
    public static let capacity=8
    public private(set) var controls:[Control]=[]
    public init(){}
    public static func permitsCC(_ cc:Int)->Bool {
        (0...119).contains(cc) && HelperCCPolicy.permits(cc) &&
        ![0,1,4,6,11,32,38,74,96,97,98,99,100,101].contains(cc) &&
        !(64...69).contains(cc)
    }
    public init?(controls:[Control]){
        guard controls.count<=Self.capacity,controls.allSatisfy(\.isValid),
              Set(controls.map(\.id)).count==controls.count,
              Set(controls.map(\.cc)).count==controls.count else{return nil}
        self.controls=controls
    }
    public func adding(_ control:Control)->Self? {Self(controls:controls+[control])}
    public func replacing(_ control:Control)->Self? {
        guard let index=controls.firstIndex(where:{$0.id==control.id}) else{return nil}
        var next=controls;next[index]=control
        return Self(controls:next)
    }
    public func removing(id:UUID)->Self? {
        guard controls.contains(where:{$0.id==id}) else{return nil}
        return Self(controls:controls.filter{$0.id != id})
    }
    public func moving(id:UUID,delta:Int)->Self? {
        guard delta == -1 || delta == 1,let index=controls.firstIndex(where:{$0.id==id}),
              controls.indices.contains(index+delta) else{return nil}
        var next=controls;next.swapAt(index,index+delta)
        return Self(controls:next)
    }
    private enum CodingKeys:String,CodingKey {case controls}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        var items=try c.nestedUnkeyedContainer(forKey:.controls)
        var next:[Control]=[]
        while !items.isAtEnd {
            guard next.count<Self.capacity else{throw DecodingError.dataCorruptedError(forKey:.controls,in:c,debugDescription:"Too many synth controls")}
            next.append(try items.decode(Control.self))
        }
        guard let bank=Self(controls:next) else{throw DecodingError.dataCorruptedError(forKey:.controls,in:c,debugDescription:"Invalid or duplicate synth control")}
        self=bank
    }
    public struct Preset:Identifiable,Sendable {
        public let name:String
        public let cc:Int
        public let neutral:Int
        public var id:Int{cc}
    }
    /// Conventional CC suggestions, not guarantees for an individual synth.
    public static let presets:[Preset] = [
        Preset(name:"Portamento time",cc:5,neutral:0),
        Preset(name:"Volume",cc:7,neutral:127),
        Preset(name:"Pan",cc:10,neutral:64),
        Preset(name:"Resonance",cc:71,neutral:0),
        Preset(name:"Release",cc:72,neutral:0),
        Preset(name:"Attack",cc:73,neutral:0),
        Preset(name:"Decay",cc:75,neutral:0),
        Preset(name:"Vibrato rate",cc:76,neutral:0),
        Preset(name:"Vibrato depth",cc:77,neutral:0),
        Preset(name:"Vibrato delay",cc:78,neutral:0),
        Preset(name:"Reverb send",cc:91,neutral:0),
        Preset(name:"Chorus send",cc:93,neutral:0)
    ].filter{permitsCC($0.cc)}
}
