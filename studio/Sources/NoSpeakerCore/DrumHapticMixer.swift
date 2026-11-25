/// The Force Touch actuator is shared. Submitting several independent
/// waveforms in the same tick can replace an earlier strike. Mix recent
/// hits into one bounded frame, with round-robin tone allocation.
public enum DrumHapticMixer {
    public static func mix(_ hits: [HapticFrame]) -> HapticFrame? {
        let safety = HapticSafetyPolicy()
        let valid = hits.prefix(16).compactMap { hit -> HapticFrame? in
            guard hit.durationMS.isFinite, hit.durationMS > 0,
                  hit.level.isFinite, hit.level > 0,
                  !hit.tones.isEmpty,
                  hit.tones.allSatisfy({ $0.frequencyHz.isFinite && $0.amplitude.isFinite }) else { return nil }
            var frame = safety.clamp(hit)
            frame.tones.removeAll { $0.amplitude <= 0 }
            return frame.tones.isEmpty ? nil : frame
        }
        guard let first = valid.first else { return nil }
        if valid.count == 1 { return first }
        // Normalize within each original strike before applying its velocity.
        // Do not sum levels across fingers: maintain the strongest hit's gain.
        let weights = valid.map { frame in
            let total = frame.tones.reduce(0.0) { $0 + $1.amplitude }
            return frame.tones.map {
                HapticTone(frequencyHz:$0.frequencyHz,amplitude:$0.amplitude/total*frame.level)
            }
        }
        var order: [Double] = []
        var amplitudes: [Double:Double] = [:]
        for index in 0..<safety.maxTonesPerFrame {
            for hit in weights where hit.count > index {
                let tone = hit[index]
                if let previous = amplitudes[tone.frequencyHz] {
                    amplitudes[tone.frequencyHz] = max(previous,tone.amplitude)
                } else if order.count < safety.maxTonesPerFrame {
                    order.append(tone.frequencyHz)
                    amplitudes[tone.frequencyHz] = tone.amplitude
                }
            }
        }
        guard let peak = amplitudes.values.max(), peak > 0 else { return nil }
        return safety.clamp(.init(
            tones:order.map { .init(frequencyHz:$0,amplitude:(amplitudes[$0] ?? 0)/peak) },
            durationMS:valid.map(\.durationMS).max() ?? first.durationMS,
            level:valid.map(\.level).max() ?? first.level
        ))
    }
}
