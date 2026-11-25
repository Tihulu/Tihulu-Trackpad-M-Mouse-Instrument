import Foundation

/// A small, deliberately narrow wire format for nominal playback planning.
/// No general JSON values, escaped keys, duplicate fields or coercion.
/// All schema keys are literal ASCII; only bpm accepts fractional/exponent
/// syntax. Object field order and JSON whitespace are unrestricted.
/// No filesystem, device, or authorization side effects.
public enum BoundedMIDIPlanInput {
    public enum Failure:LocalizedError {
        case invalid
        public var errorDescription:String? { "Invalid bounded MIDI plan JSON." }
    }
    public static let maximumBytes=65_536

    public static func decode(_ data:Data) throws -> MIDIClip {
        guard !data.isEmpty,data.count<=maximumBytes else { throw Failure.invalid }
        var parser=Parser(bytes:Array(data))
        let clip=try parser.clip()
        // Include the same capacity and timing fence as playback.
        _=try BoundedMIDIPlayback(clip:clip)
        return clip
    }

    private struct Parser {
        let bytes:[UInt8]
        var index=0
        var current:UInt8? { index<bytes.count ? bytes[index] : nil }
        mutating func space() {
            while let c=current,[9,10,13,32].contains(c) { index+=1 }
        }
        mutating func take(_ c:UInt8)->Bool {
            space()
            guard current==c else { return false }
            index+=1
            return true
        }
        mutating func require(_ c:UInt8) throws {
            guard take(c) else { throw Failure.invalid }
        }
        mutating func key() throws -> String {
            try require(34)
            let start=index
            while let c=current,(97...122).contains(c) { index+=1 }
            guard index>start,current==34,index-start<=8 else { throw Failure.invalid }
            let value=String(decoding:bytes[start..<index],as:UTF8.self)
            index+=1
            try require(58)
            return value
        }
        mutating func digits()->Bool {
            let start=index
            while let c=current,(48...57).contains(c) { index+=1 }
            return index>start
        }
        mutating func number(integer:Bool) throws -> String {
            space()
            let start=index
            if current==45 { index+=1 }
            if current==48 { index+=1 }
            else {
                guard let c=current,(49...57).contains(c),digits() else { throw Failure.invalid }
            }
            if !integer && current==46 {
                index+=1
                guard digits() else { throw Failure.invalid }
            }
            if !integer && (current==69 || current==101) {
                index+=1
                if current==43 || current==45 { index+=1 }
                guard digits() else { throw Failure.invalid }
            }
            guard index-start<=64 else { throw Failure.invalid }
            return String(decoding:bytes[start..<index],as:UTF8.self)
        }
        mutating func int() throws -> Int {
            guard let value=Int(try number(integer:true)) else { throw Failure.invalid }
            return value
        }
        mutating func note() throws -> MIDIClip.Note {
            try require(123)
            var fields:[String:Int]=[:]
            repeat {
                let name=try key()
                guard ["start","duration","channel","pitch","velocity"].contains(name),
                      fields[name]==nil else { throw Failure.invalid }
                fields[name]=try int()
            } while take(44)
            try require(125)
            guard let start=fields["start"],let duration=fields["duration"],
                  let channel=fields["channel"],let pitch=fields["pitch"],
                  let velocity=fields["velocity"] else { throw Failure.invalid }
            return .init(start:start,duration:duration,channel:channel,pitch:pitch,velocity:velocity)
        }
        mutating func notes() throws -> [MIDIClip.Note] {
            try require(91)
            var result:[MIDIClip.Note]=[]
            if take(93) { return result }
            repeat {
                guard result.count<BoundedMIDIPlayback.maximumNotes else { throw Failure.invalid }
                result.append(try note())
            } while take(44)
            try require(93)
            return result
        }
        mutating func clip() throws -> MIDIClip {
            try require(123)
            var bpm:Double?,length:Int?,items:[MIDIClip.Note]?
            var seen:Set<String>=[]
            repeat {
                let name=try key()
                guard seen.insert(name).inserted else { throw Failure.invalid }
                switch name {
                case "bpm": bpm=Double(try number(integer:false))
                case "length": length=try int()
                case "notes": items=try notes()
                default: throw Failure.invalid
                }
            } while take(44)
            try require(125)
            space()
            guard index==bytes.count,let bpm,let length,let items else { throw Failure.invalid }
            return .init(bpm:bpm,length:length,notes:items)
        }
    }
}
