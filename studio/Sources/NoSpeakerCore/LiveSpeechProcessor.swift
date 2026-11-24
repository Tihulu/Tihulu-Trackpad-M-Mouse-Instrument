import Foundation

/// Streaming analysis uses a fixed 25 ms window and 10 ms hop regardless of
/// capture packet boundaries. A nil slot represents silence, not lost time.
public struct LiveSpeechProcessor: Sendable {
    public static let hop = 0.010
    public let sampleRate: Double
    public let profile: AudioHapticProfile
    public let speechOptimized: Bool
    public let automaticGain: Bool
    public let noiseGate: Bool
    private let window: Int
    private let stride: Int
    private var samples: [Float] = []
    private var levelReference = 0.08

    public init(sampleRate: Double, profile: AudioHapticProfile = .voice,
                speechOptimized: Bool = true, automaticGain: Bool = true,
                noiseGate: Bool = true) {
        self.sampleRate = sampleRate.isFinite ? min(96_000, max(8_000, sampleRate)) : 16_000
        self.profile = profile
        self.speechOptimized = speechOptimized
        self.automaticGain = automaticGain
        self.noiseGate = noiseGate
        window = Int((self.sampleRate * 0.025).rounded())
        stride = Int((self.sampleRate * Self.hop).rounded())
    }

    public mutating func append(_ input: [Float]) -> [HapticFrame?] {
        samples.append(contentsOf: input.map { $0.isFinite ? max(-1, min(1, $0)) : 0 })
        var frames: [HapticFrame?] = []
        var offset = 0
        while offset + window <= samples.count {
            let slice = samples[offset..<(offset + window)]
            let rms = HapticSignalProcessor.rms(slice)
            levelReference = max(0.025, rms, levelReference * 0.992)
            let threshold = noiseGate ? 0.003 : 0.00015
            if rms < threshold {
                frames.append(nil)
            } else {
                let level = min(1, pow(rms / (automaticGain ? levelReference : 0.20), 0.65))
                let frame: HapticFrame?
                if profile == .voice && speechOptimized {
                    frame = Self.speechFrame(slice, rate: sampleRate, level: level)
                } else {
                    var legacy = HapticSignalProcessor.hapticEvents(
                        samples: Array(slice), sampleRate: sampleRate, profile: profile,
                        frameDuration: Double(window) / sampleRate
                    ).first?.frame
                    legacy?.level = level
                    legacy?.durationMS = 10
                    frame = legacy
                }
                frames.append(frame.map { HapticSafetyPolicy().clamp($0) })
            }
            offset += stride
        }
        if offset > 0 { samples.removeFirst(offset) }
        return frames
    }

    /// Bounded LPC spectral-envelope estimate (no iterative polynomial roots).
    /// Uses three formant regions for voiced sounds and spectral centroid for
    /// consonants. This is a low-cost experimental adaptation of the Voice
    /// mode's speech strategy, not a claim of physical speech intelligibility.
    private static func speechFrame(_ slice: ArraySlice<Float>, rate: Double,
                                    level: Double) -> HapticFrame {
        let source = Array(slice)
        let targetCount = min(400, source.count)
        // Average source bins before LPC to limit high-frequency aliasing.
        var signal = (0..<targetCount).map { i -> Double in
            let a = i * source.count / targetCount
            let b = max(a + 1, (i + 1) * source.count / targetCount)
            return source[a..<b].reduce(0.0) { $0 + Double($1) } / Double(b - a)
        }
        let analysisRate = rate * Double(targetCount) / Double(source.count)
        let mean = signal.reduce(0, +) / Double(targetCount)
        for i in signal.indices { signal[i] -= mean }
        var crossings = 0
        for i in 1..<targetCount where (signal[i] >= 0) != (signal[i - 1] >= 0) { crossings += 1 }
        var bestCorrelation = 0.0
        var bestLag = 0
        let lowLag = max(1, Int(analysisRate / 350))
        let highLag = min(targetCount / 2, Int(analysisRate / 70))
        if lowLag <= highLag {
            for lag in Swift.stride(from: lowLag, through: highLag, by: 2) {
                var ab = 0.0, aa = 0.0, bb = 0.0
                for i in Swift.stride(from: 0, to: targetCount - lag, by: 3) {
                    let a = signal[i], b = signal[i + lag]
                    ab += a * b; aa += a * a; bb += b * b
                }
                let corr = ab / max(1e-12, sqrt(aa * bb))
                if corr > bestCorrelation { bestCorrelation = corr; bestLag = lag }
            }
        }
        let voiced = bestCorrelation > 0.40 && Double(crossings) / Double(targetCount) < 0.20
        let order = 12
        let emphasized = signal.indices.map { i in
            (signal[i] - 0.95 * (i > 0 ? signal[i - 1] : 0)) *
                (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(targetCount - 1)))
        }
        var r = (0...order).map { k in
            (k..<targetCount).reduce(0.0) { $0 + emphasized[$1] * emphasized[$1 - k] }
        }
        r[0] *= 1.001
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1
        var error = max(r[0], 1e-10)
        for k in 1...order {
            var residual = r[k]
            for j in 1..<k { residual += a[j] * r[k - j] }
            let reflection = max(-0.98, min(0.98, -residual / error))
            let previous = a
            for j in 1..<k { a[j] = previous[j] + reflection * previous[k - j] }
            a[k] = reflection
            error = max(1e-10, error * (1 - reflection * reflection))
        }
        let maxHz = min(3_900, analysisRate * 0.48)
        let bins: [(Double, Double)] = Swift.stride(from: 200.0, through: maxHz, by: 50).map { hz in
            let w = 2 * Double.pi * hz / analysisRate
            var re = 0.0, im = 0.0
            for k in 0...order {
                re += a[k] * cos(w * Double(k))
                im -= a[k] * sin(w * Double(k))
            }
            return (hz, 1 / max(0.0001, sqrt(re * re + im * im)))
        }
        func peak(_ low: Double, _ high: Double, fallback: Double) -> (Double, Double) {
            bins.filter { $0.0 >= low && $0.0 <= high }.max { $0.1 < $1.1 } ?? (fallback, 1)
        }
        if voiced {
            let first = peak(200, 1_000, fallback: 500)
            let second = peak(max(650, first.0 + 200), 2_700, fallback: 1_500)
            let third = peak(max(1_700, second.0 + 200), maxHz, fallback: 2_500)
            let values = [first.1, second.1 * 1.5, third.1 * 0.35]
            let total = max(1e-9, values.reduce(0, +))
            let pitch = bestLag > 0 ? analysisRate / Double(bestLag) : 110
            return .init(tones: [
                .init(frequencyHz: first.0, amplitude: values[0] / total),
                .init(frequencyHz: second.0, amplitude: values[1] / total),
                .init(frequencyHz: third.0, amplitude: values[2] / total)
            ], durationMS: min(10, 1000 / max(70, pitch)), level: level)
        }
        let high = bins.filter { $0.0 >= 1_700 }
        let sum = max(1e-9, high.reduce(0.0) { $0 + $1.1 })
        let centroid = high.reduce(0.0) { $0 + $1.0 * $1.1 } / sum
        return .init(tones: [
            .init(frequencyHz: max(1_700, centroid), amplitude: 0.65),
            .init(frequencyHz: peak(2_200, maxHz, fallback: 3_200).0, amplitude: 0.35)
        ], durationMS: 6, level: level)
    }
}

/// A monotonic, bounded playout queue. Never replay a burst of overdue frames.
/// Silence occupies the same time slots as voiced frames.
public struct LiveHapticTimeline: Sendable {
    public let bufferSeconds: Double
    private var entries: [(Double, HapticFrame?)] = []
    private var nextDeadline: Double?
    public private(set) var dropped = 0
    public var pending: Int { entries.count }

    public init(bufferSeconds: Double = 0.15) {
        self.bufferSeconds = bufferSeconds.isFinite ? min(0.35, max(0.05, bufferSeconds)) : 0.15
    }

    public mutating func enqueue(_ frames: [HapticFrame?], now: Double) {
        guard now.isFinite, !frames.isEmpty else { return }
        if let nextDeadline, nextDeadline < now - 0.025 {
            dropped += entries.count
            entries.removeAll(keepingCapacity: true)
            self.nextDeadline = nil
        }
        var deadline = nextDeadline ?? now + bufferSeconds
        for frame in frames {
            entries.append((deadline, frame))
            deadline += LiveSpeechProcessor.hop
        }
        nextDeadline = deadline
        let excess = max(0, entries.count - 60)
        if excess > 0 {
            dropped += excess
            entries.removeFirst(excess)
            // Bound latency after overload rather than keeping stale deadlines.
            let shift = (entries.first?.0 ?? now) - (now + bufferSeconds)
            if shift > 0 {
                entries = entries.map { ($0.0 - shift, $0.1) }
                nextDeadline = deadline - shift
            }
        }
    }

    public mutating func takeDue(now: Double) -> HapticFrame? {
        guard now.isFinite else { return nil }
        var latest: (Double, HapticFrame?)?
        while let first = entries.first, first.0 <= now {
            if latest != nil { dropped += 1 }
            latest = entries.removeFirst()
        }
        guard let latest else { return nil }
        guard now - latest.0 <= 0.025 else { dropped += 1; return nil }
        return latest.1
    }
}
