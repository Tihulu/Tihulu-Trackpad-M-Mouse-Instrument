import Foundation

/// A pattern boundary includes rests, not just the last onset.
public struct PlaybackTimeline: Sendable {
    public let events: [ScheduledHapticEvent]
    public let duration: Double
    public init(events: [ScheduledHapticEvent], duration: Double? = nil, loop: Bool = false) {
        let safety = HapticSafetyPolicy()
        self.events = events.enumerated().filter {
            let e = $0.element
            return e.time.isFinite && e.time >= 0 && e.time < 1e8 &&
                e.frame.durationMS.isFinite && e.frame.durationMS > 0 &&
                e.frame.level.isFinite && !e.frame.tones.isEmpty &&
                e.frame.tones.allSatisfy { $0.frequencyHz.isFinite && $0.amplitude.isFinite }
        }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map { .init(time: $0.element.time, frame: safety.clamp($0.element.frame)) }
        let end = self.events.map { $0.time + $0.frame.durationMS / 1000 }.max() ?? 0
        let requested = duration.flatMap { $0.isFinite && $0 >= 0.0005 && $0 < 1e8 ? $0 : nil } ?? 0
        self.duration = loop && requested > 0 && self.events.allSatisfy { $0.time < requested }
            ? requested : max(requested, end)
    }
    public var canPlay: Bool { !events.isEmpty && duration > 0 }
    public static func patternDuration(bpm: Double, stepsPerBeat: Int, length: Int) -> Double? {
        guard bpm.isFinite, bpm > 0, stepsPerBeat > 0, length > 0 else { return nil }
        let value = 60 / bpm / Double(stepsPerBeat) * Double(length)
        return value.isFinite && value >= 0.0005 && value < 1e8 ? value : nil
    }
}
