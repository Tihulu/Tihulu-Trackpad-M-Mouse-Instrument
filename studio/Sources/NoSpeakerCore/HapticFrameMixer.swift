import Foundation

public enum HapticMixSource: String, CaseIterable, Hashable, Sendable {
    case touch, midi, chords, touchBar, sequencer, speech, gamepad
}

public enum HapticMixMode: Sendable {
    case continuous
    /// A time-limited frame that must not be mixed with another waveform.
    case exclusive
}

public struct HapticMixLease: Equatable, Sendable {
    public let source: HapticMixSource
    fileprivate let token: UUID
}

/// Single-owner, side-effect-free arbitration. One frame per source, no
/// playback queues, no timers and no hardware access. A future actuator
/// owner must serialize calls and perform scoped revocation before writing.
public struct HapticFrameMixer: Sendable {
    private struct Slot: Sendable {
        let lease: HapticMixLease
        let priority: Int
        let mode: HapticMixMode
        var frame: HapticFrame?
        var expiresAt: Double = 0
    }

    private struct WeightedTone {
        let hz: Double
        let weight: Double
    }

    private var slots: [HapticMixSource: Slot] = [:]
    private var lastTime = 0.0
    private let safety = HapticSafetyPolicy()
    public init() {}
    public var sourceCount: Int { slots.count }

    /// A new lease supersedes any old frame for this source only.
    public mutating func begin(_ source: HapticMixSource, priority: Int = 0,
                               mode: HapticMixMode = .continuous) -> HapticMixLease {
        let lease = HapticMixLease(source: source, token: UUID())
        slots[source] = Slot(lease: lease, priority: min(100, max(-100, priority)),
                             mode: mode, frame: nil)
        return lease
    }

    @discardableResult
    public mutating func release(_ lease: HapticMixLease) -> Bool {
        guard slots[lease.source]?.lease == lease else { return false }
        slots.removeValue(forKey: lease.source)
        return true
    }

    public mutating func releaseAll() {
        slots.removeAll(keepingCapacity: true)
    }

    /// Timestamp is the host monotonic clock in seconds. Nil explicitly clears
    /// the source. Invalid data is rejected; valid frames replace, never queue.
    @discardableResult
    public mutating func submit(_ frame: HapticFrame?, from lease: HapticMixLease,
                                masterLevel: Double = 1, now: Double) -> Bool {
        guard var slot = slots[lease.source], slot.lease == lease,
              now.isFinite, now >= lastTime else { return false }
        lastTime = now
        guard let frame else {
            slot.frame = nil
            slots[lease.source] = slot
            return true
        }
        guard masterLevel.isFinite, (0...1).contains(masterLevel),
              frame.level.isFinite, (0...1).contains(frame.level),
              frame.durationMS.isFinite, (0.5...120).contains(frame.durationMS),
              (1...6).contains(frame.tones.count),
              frame.tones.allSatisfy({
                  $0.frequencyHz.isFinite && (98...3951).contains($0.frequencyHz) &&
                  $0.amplitude.isFinite && (0...1).contains($0.amplitude)
              }) else {
            slot.frame = nil
            slots[lease.source] = slot
            return false
        }
        var safe = safety.clamp(frame)
        safe.level *= masterLevel
        safe.tones.removeAll { $0.amplitude == 0 }
        slot.frame = safe.level > 0 && !safe.tones.isEmpty ? safe : nil
        slot.expiresAt = now + safe.durationMS / 1000
        slots[lease.source] = slot
        return true
    }

    /// One bounded output slice. Expired frames are removed, and a slice
    /// cannot outlive the earliest active contribution. No catch-up replay.
    /// This is a conservative candidate policy, not calibrated physical audio.
    public mutating func render(now: Double, sliceMS: Double = 18) -> HapticFrame? {
        guard now.isFinite, now >= lastTime, sliceMS.isFinite,
              (0.5...18).contains(sliceMS) else { return nil }
        lastTime = now
        for source in Array(slots.keys) {
            if let slot = slots[source], slot.expiresAt <= now {
                slots[source]?.frame = nil
            }
        }
        let active = slots.values.filter { $0.frame != nil }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.lease.source.rawValue < $1.lease.source.rawValue
        }
        guard !active.isEmpty else { return nil }
        let audible: [Slot]
        if let exclusive = active.first(where: { $0.mode == .exclusive }) {
            audible = [exclusive]
        } else {
            audible = active
        }
        let remainingMS = (audible.map(\.expiresAt).min()! - now) * 1000
        let duration = min(sliceMS, remainingMS)
        guard duration >= 0.5 else { return nil }

        // Preserve single-source tone shape and effective gain exactly, apart
        // from the slice duration and the already validated safety limits.
        if audible.count == 1, var frame = audible.first?.frame {
            frame.durationMS = duration
            return frame
        }

        // The actual driver normalizes per-frame amplitudes. Convert each
        // source to effective tone weights before combining. Shared exact
        // frequencies use max, not sum, to avoid boosting duplicated notes.
        let voices: [[WeightedTone]] = audible.compactMap { slot in
            guard let frame = slot.frame else { return nil }
            let sum = frame.tones.reduce(0.0) { $0 + $1.amplitude }
            guard sum > 0 else { return nil }
            return frame.tones.map {
                WeightedTone(hz: $0.frequencyHz, weight: frame.level * $0.amplitude / sum)
            }.sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.hz < $1.hz
            }
        }
        // Round-robin tone selection in priority order: each active source
        // gets a chance before one source consumes all six motor voices.
        var selected: [Double] = []
        var weights: [Double: Double] = [:]
        for voiceIndex in 0..<6 {
            for voice in voices where voiceIndex < voice.count {
                let tone = voice[voiceIndex]
                if let old = weights[tone.hz] {
                    weights[tone.hz] = max(old, tone.weight)
                } else if selected.count < safety.maxTonesPerFrame {
                    selected.append(tone.hz)
                    weights[tone.hz] = tone.weight
                }
            }
        }
        let total = selected.reduce(0.0) { $0 + (weights[$1] ?? 0) }
        guard total > 0 else { return nil }
        return safety.clamp(.init(
            tones: selected.map { .init(frequencyHz: $0, amplitude: (weights[$0] ?? 0) / total) },
            durationMS: duration, level: min(safety.maxLevel, total)
        ))
    }
}
