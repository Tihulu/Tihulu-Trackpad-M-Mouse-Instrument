/// One render decision for the Touch Instrument's shared physical motor.
/// Keep the existing standalone drum waveform and melodic refresh unchanged
/// when only one kind is sounding. For mixed playback, refresh a bounded
/// slice containing both sources instead of blocking melody until drum end.
public struct TouchHapticRenderPlan: Sendable {
    private var tail: HapticFrame?
    private var expiresAt: Double = 0
    private var lastWasMixed = false
    private var lastTime: Double?
    public init() {}

    public mutating func reset() {
        tail = nil
        expiresAt = 0
        lastWasMixed = false
        lastTime = nil
    }

    public mutating func next(hits: [HapticFrame], melody: HapticFrame?, now: Double) -> HapticFrame? {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else {
            reset()
            return nil
        }
        lastTime = now
        let strike = DrumHapticMixer.mix(hits)
        let voice = melody.flatMap { DrumHapticMixer.mix([$0]) }
        if let strike {
            tail = strike
            expiresAt = now + strike.durationMS/1000
            lastWasMixed = false
        }
        let remaining = (expiresAt-now)*1000
        if remaining < 0.5 {
            tail = nil
            lastWasMixed = false
        }
        if let voice {
            if let drum = tail {
                // Both sources get a fair chance in the six-tone budget.
                // Do not extend the percussion tail when refreshing it.
                if var mixed = DrumHapticMixer.mix([drum,voice]) {
                    mixed.durationMS = min(18,remaining)
                    lastWasMixed = true
                    return mixed
                }
            }
            return voice
        }
        if let strike { return strike }
        if lastWasMixed, var drum = tail {
            // Melody just ended. Finish only the original remaining tail;
            // do not reissue a standalone strike on every timer tick.
            lastWasMixed = false
            drum.durationMS = remaining
            return drum
        }
        return nil
    }
}
