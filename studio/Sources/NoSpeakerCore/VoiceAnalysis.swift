import Foundation

/// Speech analysis adapted from os6/nospeaker v1.0 by Cody Collier (MIT).
/// The downstream structure is different, but the LPC/formant strategy intentionally
/// preserves the behavior of the original project.
public struct HapticVoiceFrame: Sendable, Equatable {
    public var formants: [Double] = [500, 1_500, 2_500]
    public var amplitudes: [Double] = [1, 0.5, 0.25]
    public var level: Double = 0
    public var voiced = false
    public var fundamentalHz = 110.0

    public init() {}
}

private struct ComplexValue {
    var re: Double
    var im: Double

    static func + (lhs: Self, rhs: Self) -> Self { .init(re: lhs.re + rhs.re, im: lhs.im + rhs.im) }
    static func - (lhs: Self, rhs: Self) -> Self { .init(re: lhs.re - rhs.re, im: lhs.im - rhs.im) }
    static func * (lhs: Self, rhs: Self) -> Self {
        .init(re: lhs.re * rhs.re - lhs.im * rhs.im, im: lhs.re * rhs.im + lhs.im * rhs.re)
    }
    static func / (lhs: Self, rhs: Self) -> Self {
        let divisor = rhs.re * rhs.re + rhs.im * rhs.im
        return .init(
            re: (lhs.re * rhs.re + lhs.im * rhs.im) / divisor,
            im: (lhs.im * rhs.re - lhs.re * rhs.im) / divisor
        )
    }
}

public enum VoiceAnalysisError: Error, LocalizedError {
    case invalidSample
    public var errorDescription: String? { "Voice audio contains an invalid sample." }
}

public enum HapticVoiceAnalyzer {
    public static let hopSeconds = 0.010
    public static let sampleRate = 16_000.0

    private static func lpc(_ input: [Double], order: Int) -> ([Double], Double) {
        var autocorrelation = [Double](repeating: 0, count: order + 1)
        for k in 0...order {
            var sum = 0.0
            for i in k..<input.count { sum += input[i] * input[i - k] }
            autocorrelation[k] = sum
        }
        var coefficients = [Double](repeating: 0, count: order + 1)
        coefficients[0] = 1
        guard autocorrelation[0] > 1e-12 else { return (coefficients, 0) }
        autocorrelation[0] *= 1.0001
        var error = autocorrelation[0]
        for i in 1...order {
            var accumulator = autocorrelation[i]
            for j in 1..<i { accumulator += coefficients[j] * autocorrelation[i - j] }
            let reflection = -accumulator / error
            var next = coefficients
            for j in 1..<i { next[j] = coefficients[j] + reflection * coefficients[i - j] }
            next[i] = reflection
            coefficients = next
            error *= 1 - reflection * reflection
        }
        return (coefficients, error)
    }

    private static func roots(_ coefficients: [Double]) -> [ComplexValue] {
        let order = coefficients.count - 1
        guard order > 0 else { return [] }
        var roots = (0..<order).map { index -> ComplexValue in
            let angle = 2 * Double.pi * Double(index) / Double(order) + 0.4
            return .init(re: 0.9 * cos(angle), im: 0.9 * sin(angle))
        }
        func polynomial(_ value: ComplexValue) -> ComplexValue {
            var sum = ComplexValue(re: 1, im: 0)
            for k in 1...order { sum = sum * value + .init(re: coefficients[k], im: 0) }
            return sum
        }
        for _ in 0..<300 {
            var moved = 0.0
            for i in 0..<order {
                var denominator = ComplexValue(re: 1, im: 0)
                for j in 0..<order where j != i { denominator = denominator * (roots[i] - roots[j]) }
                if denominator.re == 0 && denominator.im == 0 { denominator = .init(re: 1e-12, im: 0) }
                let step = polynomial(roots[i]) / denominator
                roots[i] = roots[i] - step
                moved = max(moved, abs(step.re) + abs(step.im))
            }
            if moved < 1e-10 { break }
        }
        return roots
    }

    public static func analyze(_ input: [Float]) -> [HapticVoiceFrame] {
        // Non-throwing compatibility path rejects invalid PCM without emitting events.
        (try? analyzeImpl(input,cancellation:nil)) ?? []
    }

    public static func analyze(_ input: [Float], cancellation: VoiceRenderCancellation) throws -> [HapticVoiceFrame] {
        try analyzeImpl(input,cancellation:cancellation)
    }

    private static func analyzeImpl(_ input: [Float], cancellation: VoiceRenderCancellation?) throws -> [HapticVoiceFrame] {
        try cancellation?.check()
        let windowSize = Int(0.025 * sampleRate)
        let hopSize = Int(hopSeconds * sampleRate)
        let order = 18
        guard input.count >= windowSize else { return [] }
        let hamming = (0..<windowSize).map {
            0.54 - 0.46 * cos(2 * .pi * Double($0) / Double(windowSize - 1))
        }
        var frames: [HapticVoiceFrame] = []
        var rmsValues: [Double] = []
        var previous = HapticVoiceFrame()
        var offset = 0
        let frameCount = (input.count-windowSize)/hopSize+1
        frames.reserveCapacity(frameCount)
        rmsValues.reserveCapacity(frameCount)
        var segment = [Double](repeating:0,count:windowSize)
        var preEmphasized = [Double](repeating:0,count:windowSize)

        while offset + windowSize <= input.count {
            try cancellation?.check()
            for index in 0..<windowSize {
                let sample = input[offset+index]
                guard sample.isFinite else { throw VoiceAnalysisError.invalidSample }
                segment[index] = Double(sample)
            }
            rmsValues.append(sqrt(segment.reduce(0) { $0 + $1 * $1 } / Double(windowSize)))
            var frame = previous

            var zeroCrossings = 0
            for index in 1..<windowSize where (segment[index] >= 0) != (segment[index - 1] >= 0) { zeroCrossings += 1 }
            var bestLag = 0
            var bestCorrelation = 0.0
            for lag in Int(sampleRate / 300)...Int(sampleRate / 70) where lag < windowSize - 40 {
                var sum = 0.0
                var energyA = 0.0
                var energyB = 0.0
                for index in 0..<(windowSize - lag) {
                    sum += segment[index] * segment[index + lag]
                    energyA += segment[index] * segment[index]
                    energyB += segment[index + lag] * segment[index + lag]
                }
                let correlation = sum / max(sqrt(energyA * energyB), 1e-12)
                if correlation > bestCorrelation {
                    bestCorrelation = correlation
                    bestLag = lag
                }
            }
            frame.voiced = bestCorrelation > 0.35 && Double(zeroCrossings) / Double(windowSize) < 0.22
            if frame.voiced, bestLag > 0 { frame.fundamentalHz = sampleRate / Double(bestLag) }

            for index in 0..<windowSize {
                preEmphasized[index] = (segment[index] - 0.97 * (index > 0 ? segment[index - 1] : 0)) * hamming[index]
            }
            let (coefficients, error) = lpc(preEmphasized, order: order)
            var candidates: [Double] = []
            if error > 0 {
                for root in roots(coefficients) where root.im > 0 {
                    let hz = atan2(root.im, root.re) * sampleRate / (2 * .pi)
                    let bandwidth = -log(max(1e-9, sqrt(root.re * root.re + root.im * root.im))) * sampleRate / .pi
                    if hz > 150, hz < 4_200, bandwidth < 500 { candidates.append(hz) }
                }
            }
            func pick(_ lower: Double, _ upper: Double, near target: Double) -> Double? {
                candidates.filter { $0 >= lower && $0 <= upper }.min { abs($0 - target) < abs($1 - target) }
            }
            if let f1 = pick(200, 1_000, near: previous.formants[0]) { frame.formants[0] = f1 }
            if let f2 = pick(max(frame.formants[0] + 200, 650), 2_700, near: previous.formants[1]) { frame.formants[1] = f2 }
            if let f3 = pick(max(frame.formants[1] + 300, 1_700), 3_900, near: previous.formants[2]) { frame.formants[2] = f3 }

            if error > 0 {
                frame.amplitudes = frame.formants.map { hz in
                    let omega = 2 * Double.pi * hz / sampleRate
                    var re = 0.0
                    var im = 0.0
                    for k in 0...order {
                        re += coefficients[k] * cos(omega * Double(k))
                        im -= coefficients[k] * sin(omega * Double(k))
                    }
                    return 1 / max(sqrt(re * re + im * im), 1e-6)
                }
            }
            frames.append(frame)
            previous = frame
            offset += hopSize
        }

        let peak = rmsValues.max() ?? 1
        for index in frames.indices {
            if index % 64 == 0 { try cancellation?.check() }
            let relative = rmsValues[index] / max(peak, 1e-9)
            frames[index].level = relative < 0.02 ? 0 : min(1, pow(relative, 0.45))
            if frames[index].level == 0 { frames[index].voiced = false }
        }

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let raw = frames
        for index in frames.indices {
            if index % 64 == 0 { try cancellation?.check() }
            let lower = max(0, index - 2)
            let upper = min(frames.count - 1, index + 2)
            for formantIndex in 0..<3 {
                frames[index].formants[formantIndex] = median((lower...upper).map { raw[$0].formants[formantIndex] })
            }
            frames[index].fundamentalHz = min(250, max(70, median((lower...upper).map { raw[$0].fundamentalHz })))
        }
        try cancellation?.check()
        return frames
    }

    public static func hapticEvents(frames: [HapticVoiceFrame], safety: HapticSafetyPolicy = .init()) -> [ScheduledHapticEvent] {
        frames.enumerated().compactMap { index, frame in
            guard frame.level > 0 else { return nil }
            let tones: [HapticTone]
            let durationMS: Double
            if frame.voiced {
                let weights = [frame.amplitudes[0], frame.amplitudes[1] * 1.8]
                let total = max(weights[0] + weights[1], 1e-9)
                tones = [
                    HapticTone(frequencyHz: frame.formants[0], amplitude: weights[0] / total),
                    HapticTone(frequencyHz: frame.formants[1], amplitude: weights[1] / total)
                ]
                durationMS = min(10, 1_000 / max(70, frame.fundamentalHz))
            } else {
                // Deterministic high-frequency consonant representation for reproducible playback/tests.
                let choices = [2_750.0, 3_250.0, 3_750.0]
                let frequency = choices[index % choices.count]
                tones = [HapticTone(frequencyHz: frequency, amplitude: 1)]
                durationMS = 4
            }
            return ScheduledHapticEvent(
                time: Double(index) * hopSeconds,
                frame: safety.clamp(.init(tones: tones, durationMS: durationMS, level: frame.level))
            )
        }
    }
}
