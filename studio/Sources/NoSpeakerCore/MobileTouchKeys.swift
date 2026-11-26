import Foundation

/// Pure bounded mapping for a future native touch piano surface.
/// The caller must supply a complete snapshot of currently owned touches
/// from the active view generation, not historical gestures or event queues.
/// Invalid snapshots return nil (retire transport); empty is explicit release.
/// No socket, synthetic timestamps, MIDI destination or automatic rearm.
public struct MobileTouchKeys:Sendable {
    public static let maximumContacts=10
    public struct Contact:Sendable {
        public let id:Int
        public let x:Double
        public init(id:Int,x:Double){self.id=id;self.x=x}
    }
    public let keys:[Int]
    public init?(authorized:Int){
        guard authorized>0,authorized<(1<<25) else{return nil}
        keys=(0..<25).filter{authorized & (1<<$0) != 0}
    }
    public func output(_ contacts:[Contact])->MobileAirOutput? {
        guard contacts.count<=Self.maximumContacts else{return nil}
        var seen=Set<Int>()
        var mask=0
        for c in contacts {
            guard c.id>=0,seen.insert(c.id).inserted,c.x.isFinite,
                  c.x>=0,c.x<=1 else{return nil}
            let column=min(keys.count-1,Int(c.x*Double(keys.count)))
            mask |= 1<<keys[column]
        }
        return .init(keys:mask)
    }
}
