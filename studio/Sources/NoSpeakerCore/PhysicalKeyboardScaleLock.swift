import Foundation

/// Standard 12-TET single-source, single-channel scale filter. Injected
/// sink only, no native subscription or MIDI output port. Mapping is frozen.
/// The adapter must own a dedicated output lane, explicitly arm with all
/// keys/pedal released, and retire on source loss. No shared-port panic.
public struct PhysicalKeyboardScaleLock: Sendable {
    public enum Result: Equatable, Sendable {
        case delivered, muted, ignored, invalid, retired, failed
    }
    public let map:PhysicalKeyboardScaleMap
    public let channel:Int
    public private(set) var retired=false
    private var held=Set<Int>()
    private var pedal=false
    public var pendingCleanup:Bool {retired && (!held.isEmpty || pedal)}
    public init?(intervals:[Int],root:Int,channel:Int=0,allowOutsideScale:Bool=false){
        guard (0...15).contains(channel),
              let map=PhysicalKeyboardScaleMap.standardLock(intervals:intervals,root:root,allowOutsideScale:allowOutsideScale) else{return nil}
        self.map=map;self.channel=channel
    }
    public mutating func note(_ note:Int,velocity:Int,send:(SensorCommand)->Bool)->Result {
        guard !retired else{return .retired}
        guard (0...127).contains(note),(0...127).contains(velocity) else{return .invalid}
        switch map.output(note) {
        case .tuned, .originalMIDI: break
        case .muted, .unavailable: return .muted
        }
        let target=SensorDestination(.note,channel:channel,number:note)
        if velocity==0 {
            guard held.contains(note) else{return .ignored}
            guard send(.init(target,value:0)) else{return fail(send:send)}
            held.remove(note)
        } else {
            // No duplicate retrigger; the physical release owns the note.
            guard held.insert(note).inserted else{return .ignored}
            guard send(.init(target,value:velocity)) else{return fail(send:send)}
        }
        return .delivered
    }
    public mutating func sustain(_ value:Int,send:(SensorCommand)->Bool)->Result {
        guard !retired else{return .retired}
        guard (0...127).contains(value) else{return .invalid}
        let down=value>=64
        guard down != pedal else{return .ignored}
        if down {pedal=true}
        guard send(.init(.init(.sustain,channel:channel),value:down ? 127:0)) else{return fail(send:send)}
        pedal=down
        return .delivered
    }
    private mutating func fail(send:(SensorCommand)->Bool)->Result {
        _=stop(send:send);return .failed
    }
    @discardableResult public mutating func stop(send:(SensorCommand)->Bool)->Bool {
        retired=true
        for note in held.sorted(){
            if send(.init(.init(.note,channel:channel,number:note),value:0)){held.remove(note)}
        }
        if pedal,send(.init(.init(.sustain,channel:channel),value:0)){pedal=false}
        return !pendingCleanup
    }
}
