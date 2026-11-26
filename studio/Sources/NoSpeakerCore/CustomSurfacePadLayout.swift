import Foundation

/// Offline, device-specific layout. Integer coordinates in 0...10000
/// make adjacent boundaries exact. No route authorization or MIDI output.
public struct CustomSurfacePadLayout: Codable, Equatable, Sendable {
    public enum Surface:String,Codable,CaseIterable,Sendable {
        case trackpad,magicMouse,touchBar,phone,tablet
    }
    public enum Assignment:Codable,Equatable,Sendable {
        case note(Int)
        case chord([Int])
        case degree(Int)
        case drum(Int)
        case helper(SensorDestination)
        case xy(SensorDestination,SensorDestination)
        public var isValid:Bool {
            switch self {
            case .note(let n),.drum(let n): return (0...127).contains(n)
            case .chord(let notes): return (1...15).contains(notes.count) && Set(notes).count==notes.count && notes.allSatisfy{(0...127).contains($0)}
            case .degree(let step): return (-1408...1408).contains(step)
            case .helper(let d): return Self.safeHelper(d)
            case .xy(let x,let y):
                return x != y && Self.continuous(x) && Self.continuous(y)
            }
        }
        private static func safeHelper(_ d:SensorDestination)->Bool {
            d.isValid && d.kind != .note && (d.kind != .controlChange || !( [0,6,32,38,96,97,98,99,100,101].contains(d.number) || (120...127).contains(d.number) ))
        }
        private static func continuous(_ d:SensorDestination)->Bool {
            safeHelper(d) && (d.kind == .pitchBend || (d.kind == .controlChange && !(64...69).contains(d.number)))
        }
    }
    public struct Pad:Codable,Equatable,Sendable,Identifiable {
        public let id:String
        public let label:String
        public let x:Int
        public let y:Int
        public let width:Int
        public let height:Int
        public let assignment:Assignment
        public init(id:String,label:String,x:Int,y:Int,width:Int,height:Int,assignment:Assignment){
            self.id=id;self.label=label;self.x=x;self.y=y;self.width=width;self.height=height;self.assignment=assignment
        }
        public var isValid:Bool {
            !id.isEmpty && id.utf8.count<=64 && label.utf8.count<=64 &&
            !id.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)} &&
            !label.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)} &&
            (0..<10000).contains(x) && (0..<10000).contains(y) &&
            (1...10000).contains(width) && (1...10000).contains(height) &&
            width<=10000-x && height<=10000-y && assignment.isValid
        }
        /// A geometry-only edit must retain the exact assignment, including
        /// a chord or a custom helper destination not exposed by an editor.
        public func editingGeometry(label:String,x:Int,y:Int,width:Int,height:Int)->Self {
            .init(id:id,label:label,x:x,y:y,width:width,height:height,assignment:assignment)
        }
        fileprivate func overlaps(_ other:Self)->Bool {
            x<other.x+other.width && other.x<x+width && y<other.y+other.height && other.y<y+height
        }
    }
    public let surface:Surface
    public let pads:[Pad]
    public init?(surface:Surface,pads:[Pad]){
        guard Self.valid(surface:surface,pads:pads) else{return nil}
        self.surface=surface;self.pads=pads
    }
    private static func valid(surface:Surface,pads:[Pad])->Bool {
        guard (1...64).contains(pads.count),Set(pads.map(\.id)).count==pads.count,
              pads.allSatisfy(\.isValid) else{return false}
        if surface == .touchBar && !pads.allSatisfy({$0.y==0 && $0.height==10000}){return false}
        for i in pads.indices {
            for j in pads.indices where j>i {
                if pads[i].overlaps(pads[j]){return false}
            }
        }
        return true
    }
    /// Validated edits never mutate the original or silently resolve overlaps.
    public func replacing(_ pad:Pad)->Self? {
        guard let index=pads.firstIndex(where:{$0.id==pad.id}) else{return nil}
        var next=pads;next[index]=pad
        return Self(surface:surface,pads:next)
    }
    public func adding(_ pad:Pad)->Self? {Self(surface:surface,pads:pads+[pad])}
    /// Find a deterministic empty rectangle using exact integer boundaries.
    /// No existing region is moved, resized or overwritten. Touch Bar
    /// remains one dimensional; all candidates must span its full height.
    public func addingInGap(id:String,label:String,width:Int,height:Int,assignment:Assignment)->Self? {
        guard pads.count<64,(1...10000).contains(width),(1...10000).contains(height),
              surface != .touchBar || height==10000 else{return nil}
        let xs=Set([0]+pads.map{$0.x+$0.width}).sorted()
        let ys=surface == .touchBar ? [0]:Set([0]+pads.map{$0.y+$0.height}).sorted()
        for y in ys where y<=10000-height {
            for x in xs where x<=10000-width {
                let pad=Pad(id:id,label:label,x:x,y:y,width:width,height:height,assignment:assignment)
                guard pad.isValid else{return nil}
                if !pads.contains(where:{pad.overlaps($0)}) {return adding(pad)}
            }
        }
        return nil
    }
    public func removing(id:String)->Self? {
        guard pads.contains(where:{$0.id==id}) else{return nil}
        return Self(surface:surface,pads:pads.filter{$0.id != id})
    }
    public static func grid(surface:Surface,columns:Int,rows:Int,firstNote:Int=60)->Self? {
        guard (1...16).contains(columns),(1...16).contains(rows),
              columns*rows<=64,(0...127).contains(firstNote),
              firstNote+columns*rows-1<=127 else{return nil}
        let pads=(0..<(columns*rows)).map{index in
            let x=index%columns,y=index/columns
            let left=x*10000/columns,top=y*10000/rows
            return Pad(id:"pad-"+String(index+1),label:"Pad "+String(index+1),x:left,y:top,
                       width:(x+1)*10000/columns-left,height:(y+1)*10000/rows-top,
                       assignment:.note(firstNote+index))
        }
        return Self(surface:surface,pads:pads)
    }
    private enum CodingKeys:String,CodingKey {case surface,pads}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let surface=try c.decode(Surface.self,forKey:.surface)
        let pads=try c.decode([Pad].self,forKey:.pads)
        guard let valid=Self(surface:surface,pads:pads) else{
            throw DecodingError.dataCorruptedError(forKey:.pads,in:c,debugDescription:"Invalid or overlapping physical pad layout")
        }
        self=valid
    }
    /// Top-left normalized coordinates. Device adapter must convert its
    /// own axis direction. Right/bottom edge belongs to the last cell.
    public func pad(x:Double,y:Double)->Pad? {
        guard x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y) else{return nil}
        // Compare against normalized boundaries directly. Multiplying a
        // decimal boundary by 10000 and truncating can move it one cell left.
        func contains(_ value:Double,_ start:Int,_ size:Int)->Bool {
            let end=start+size
            return value>=Double(start)/10000 &&
                (value<Double(end)/10000 || (end==10000 && value==1))
        }
        return pads.first{contains(x,$0.x,$0.width) && contains(y,$0.y,$0.height)}
    }
}
