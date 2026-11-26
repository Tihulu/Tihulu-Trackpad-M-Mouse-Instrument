/// Shared momentary pedal / deliberate slide-lock state. No MIDI sends.
/// Separate owners cannot release another owner's pedal. A retired
/// gesture must be rejected by the enclosing session epoch.
public struct SustainSlideLock: Equatable, Sendable {
    public enum Owner:Hashable,Sendable {case screen,native}
    public enum Phase:Equatable,Sendable {case idle,held,locked,unlocking}
    public enum Event:Sendable {case begin,end(lock:Bool),cancel}
    private var phases:[Owner:Phase]=[:]
    public init(){}
    public func phase(_ owner:Owner)->Phase {phases[owner] ?? .idle}
    public var active:Bool {phases.values.contains{ $0 == .held || $0 == .locked }}
    /// Returns only aggregate transitions, not redundant pedal edges.
    @discardableResult public mutating func apply(_ event:Event,owner:Owner)->Bool? {
        let before=active
        switch (phase(owner),event) {
        case (.idle,.begin):phases[owner] = .held
        case (.locked,.begin):phases[owner] = .unlocking
        case (.held,.end(let lock)):phases[owner] = lock ? .locked : .idle
        case (.unlocking,.end):phases[owner] = .idle
        case (_,.cancel):phases.removeValue(forKey:owner)
        default:break
        }
        return active == before ? nil : active
    }
    @discardableResult public mutating func reset()->Bool? {
        let before=active;phases.removeAll();return before ? false:nil
    }
}
