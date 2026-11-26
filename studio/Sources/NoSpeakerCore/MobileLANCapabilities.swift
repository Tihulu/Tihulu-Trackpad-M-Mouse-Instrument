import Foundation

/// Strict subset for the first native single-family transport proof.
/// No metadata disclosure, admission, TLS or network side effects. A host
/// manifest is meaningful only after authenticated socket admission.
public enum MobileLANCapabilities {
    public struct Manifest: Equatable, Sendable {
        public let piano: Int
        public let pedals: Int
        public func hybridLane(mask: Int) -> MobileAirWireLane? {
            guard piano > 0, (1...7).contains(pedals), (1...7).contains(mask), mask & pedals == mask else { return nil }
            return .xyzHybrid(mask: mask, pedals: pedals, piano: piano)
        }
        public func xyzLane(mask: Int) -> MobileAirWireLane? {
            guard piano == 0, (1...7).contains(mask), mask & pedals == mask else { return nil }
            return .xyz(mask: mask, authorized: pedals)
        }
        public func keysLane() -> MobileAirWireLane? {
            guard piano>0,pedals==0 else {return nil}
            return .keys(authorized:piano)
        }
        public func helperLane(index:Int) -> MobileAirWireLane? {
            guard piano==0,(0..<3).contains(index),pedals&(1<<index) != 0 else {return nil}
            return .helper(index:index,authorized:pedals)
        }
    }
    /// Host v7 JSON is a flat fixed manifest. Require integer token grammar
    /// and exact booleans; reject duplicates, aliases and unknown fields.
    public static func parseSingleFamily(_ data:Data) -> Manifest? { parse(data, hybrid: false) }
    static func parse(_ data: Data, hybrid: Bool) -> Manifest? {
        guard data.count<=RemoteTouchFrame.maximumBytes,
              let input=String(data:data,encoding:.utf8),
              input.utf8.allSatisfy({$0<128}),
              let keys=RemoteFlatJSON.uniqueKeys(data),
              keys==Set(["kind","version","touch","tilt","acceleration","rotation","airDrums","drums","piano","pedals"]) else {return nil}
        let whitespace=CharacterSet(charactersIn:" \t\r\n")
        let text=input.trimmingCharacters(in:whitespace)
        guard text.first=="{",text.last=="}" else {return nil}
        var fields:[String:String]=[:]
        for member in text.dropFirst().dropLast().split(separator:",",omittingEmptySubsequences:false) {
            let parts=member.split(separator:":",omittingEmptySubsequences:false)
            guard parts.count==2 else {return nil}
            let key=parts[0].trimmingCharacters(in:whitespace)
            let value=parts[1].trimmingCharacters(in:whitespace)
            guard key.first=="\"",key.last=="\"",key.count>=2 else {return nil}
            let name=String(key.dropFirst().dropLast())
            guard keys.contains(name),fields[name]==nil else {return nil}
            fields[name]=value
        }
        guard fields["kind"]=="\"capabilities\"",fields["version"]=="7",
              ["touch","tilt","acceleration","rotation","airDrums"].allSatisfy({fields[$0]=="false"}),
              fields["drums"]=="0" else {return nil}
        func integer(_ name:String,_ max:Int)->Int? {
            guard let s=fields[name],!s.isEmpty,s.utf8.allSatisfy({(48...57).contains($0)}),
                  let v=Int(s),String(v)==s,(0...max).contains(v) else {return nil}
            return v
        }
        guard let piano=integer("piano",(1<<25)-1),let pedals=integer("pedals",63) else {return nil}
        if hybrid {
            guard piano > 0, (1...7).contains(pedals) else { return nil }
        } else if !((piano>0 && pedals==0)||(piano==0 && pedals&7 != 0)) { return nil }
        return Manifest(piano:piano,pedals:pedals)
    }
}
