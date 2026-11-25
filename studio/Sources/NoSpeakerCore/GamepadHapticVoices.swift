import Foundation

/// Consumes the already reconciled router output, never raw button events.
/// The same first-on/last-off ownership drives both MIDI and local haptics.
public struct GamepadHapticVoices: Sendable {
    private var notes = LegacyIncomingNotes()
    private var bends: [Int:Int] = [:]
    private var expression: [Int:Int] = [:]
    private var volume: [Int:Int] = [:]
    public init() {}

    /// First native haptic slice deliberately admits gamepad-only patches.
    public static func supports(_ patch: InstrumentPatch) -> Bool {
        patch.isValid && !patch.routes.isEmpty &&
            patch.routes.allSatisfy { GamepadFrame.sources.contains($0.source) }
    }

    public mutating func apply(_ command: SensorCommand) {
        let d = command.destination, v = command.value
        guard d.isValid else { return }
        switch d.kind {
        case .note:
            guard (0...127).contains(v) else { return }
            if v == 0 { _ = notes.noteOff(channel:d.channel,note:d.number) }
            else { _ = notes.noteOn(channel:d.channel,note:d.number,velocity:v) }
        case .sustain:
            guard v == 0 || v == 127 else { return }
            _ = notes.control(channel:d.channel,controller:64,value:v)
        case .pitchBend:
            guard (0...16383).contains(v) else { return }
            bends[d.channel] = v
        case .controlChange:
            guard (0...127).contains(v) else { return }
            if d.number == 7 { volume[d.channel] = v }
            if d.number == 11 { expression[d.channel] = v }
        }
    }

    public func frame() -> HapticFrame? {
        let policy = HapticSafetyPolicy()
        // Independent MIDI channels retain independent bend/level. The
        // physical actuator is shared and limited to six audible tones.
        var byFrequency: [Double:Double] = [:]
        for (key,state) in notes.notes {
            let bend = Double((bends[key.channel] ?? 8192)-8192)/8192*2
            let gain = Double(volume[key.channel] ?? 127)/127 * Double(expression[key.channel] ?? 127)/127
            guard gain > 0,
                  let rendered = NoteHapticRenderer.frame(notes:[key.note],velocity:state.velocity,
                       safety:policy,semitoneOffset:bend,expression:gain),
                  let tone = rendered.tones.first else { continue }
            byFrequency[tone.frequencyHz] = max(byFrequency[tone.frequencyHz] ?? 0,rendered.level)
        }
        let selected = byFrequency.keys.sorted().prefix(policy.maxTonesPerFrame)
        guard let peak = selected.compactMap({ byFrequency[$0] }).max(), peak > 0 else { return nil }
        let tones = selected.map { HapticTone(frequencyHz:$0,amplitude:(byFrequency[$0] ?? 0)/peak/Double(selected.count)) }
        return policy.clamp(.init(tones:tones,durationMS:18,level:peak))
    }
}
