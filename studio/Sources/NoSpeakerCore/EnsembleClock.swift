import Foundation

/// MIDI timing clock at 24 pulses per quarter note. Absolute host deadlines
/// avoid accumulating sleep error; a missed deadline stops rather than bursts.
public struct EnsembleClock: Sendable {
    public enum Message: UInt8, Sendable { case start = 0xFA, clock = 0xF8, stop = 0xFC }
    public enum Tick: Equatable, Sendable { case wait(Double), pulse(beat: Int?), fault }
    public let bpm: Double
    public let beatsPerBar: Int
    public let interval: Double
    private let origin: Double
    private var last: Double
    private var count = 0
    private var failed = false
    public init?(bpm:Double,beatsPerBar:Int,now:Double) {
        guard bpm.isFinite,(20...300).contains(bpm),(2...7).contains(beatsPerBar),
              now.isFinite,now >= 0,now < 1e12 else { return nil }
        self.bpm = bpm; self.beatsPerBar = beatsPerBar
        interval = 60/bpm/24; origin = now; last = now
    }
    public mutating func tick(now:Double) -> Tick {
        guard !failed, now.isFinite,now >= last,count < Int.max-1 else { failed = true; return .fault }
        last = now
        let deadline = origin + Double(count+1)*interval
        if now < deadline { return .wait(deadline-now) }
        guard now-deadline < min(0.020,interval*0.75) else { failed = true; return .fault }
        let beat = count % 24 == 0 ? (count/24)%beatsPerBar+1 : nil
        count += 1
        return .pulse(beat:beat)
    }
}


/// Keep independent note/selector and realtime-clock cleanup attempts
/// ahead of native teardown. Failure of either must not skip the other.
public enum BuilderStopSequence {
    public struct Result:Equatable,Sendable {
        public let notesReleased:Bool
        public let clockReleased:Bool
        public var complete:Bool { notesReleased && clockReleased }
        public func notice(reason:String? = nil) -> String {
            var parts=[reason ?? "Builder idle"]
            if !notesReleased { parts.append("MIDI note or selector release failed. Reset DAW and retry Stop.") }
            if !clockReleased { parts.append("MIDI Clock Stop failed. Reset DAW and retry Stop.") }
            return parts.joined(separator:" ")
        }
    }
    public static func release(notes:()->Bool,clock:()->Bool) -> Result {
        let notesReleased=notes()
        let clockReleased=clock()
        return Result(notesReleased:notesReleased,clockReleased:clockReleased)
    }
    public static func run(invalidate:()->Void,notes:()->Bool,clock:()->Bool,
                           teardown:()->Void) -> Result {
        invalidate()
        let result=release(notes:notes,clock:clock)
        teardown()
        return result
    }
}
