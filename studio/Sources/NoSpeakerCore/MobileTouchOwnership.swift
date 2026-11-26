import Foundation

/// Single explicitly armed touch owner. Only complete current contact
/// snapshots are accepted. Cancellation or invalid transitions are terminal
/// for this owner; a new UI generation must be explicitly armed.
public struct MobileTouchOwnership:Sendable {
    public enum Change:Sendable {case began, moved, ended, cancelled}
    private let mapper:MobileTouchKeys
    private var active=Set<Int>()
    public private(set) var retired=false
    public private(set) var output=MobileAirOutput()
    public var keys:[Int]{mapper.keys}
    public init?(authorized:Int){
        guard let mapper=MobileTouchKeys(authorized:authorized) else{return nil}
        self.mapper=mapper
    }
    @discardableResult public mutating func retire()->MobileAirOutput {
        retired=true;active.removeAll();output = .init()
        return output
    }
    public mutating func update(_ change:Change,contacts:[MobileTouchKeys.Contact])->MobileAirOutput? {
        guard !retired else{return nil}
        if case .cancelled=change{retire();return nil}
        guard let next=mapper.output(contacts) else{retire();return nil}
        let ids=Set(contacts.map(\.id))
        let valid:Bool
        switch change {
        case .began:valid=active.isStrictSubset(of:ids)
        case .moved:valid = !active.isEmpty && ids==active
        case .ended:valid=ids.isStrictSubset(of:active)
        case .cancelled:valid=false
        }
        guard valid else{retire();return nil}
        active=ids;output=next
        return next
    }
}
