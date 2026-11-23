import Foundation

public struct SpectralPeak: Sendable, Equatable {
    public let frequencyHz: Double
    public let magnitude: Double
}

public enum HapticSignalProcessor {
    public static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    public static func zeroCrossingRate(_ samples: ArraySlice<Float>) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        var previous = samples[samples.startIndex]
        for index in samples.indices.dropFirst() {
            let current = samples[index]
            if (previous >= 0) != (current >= 0) { crossings += 1 }
            previous = current
        }
        return Double(crossings) / Double(samples.count - 1)
    }

    /// A compact DFT tuned for haptic conversion. It deliberately scans only the
    /// trackpad's useful frequency range instead of producing a full FFT.
    public static func dominantPeaks(
        samples: ArraySlice<Float>,
        sampleRate: Double,
        minFrequency: Double = 98,
        maxFrequency: Double = 3_951,
        peakCount: Int = 4,
        frequencyStep: Double = 24
    ) -> [SpectralPeak] {
        guard samples.count >= 16, sampleRate > 0, peakCount > 0 else { return [] }
        let values = Array(samples)
        let count = values.count
        let center = Double(count - 1) / 2
        var candidates: [SpectralPeak] = []
        var frequency = max(minFrequency, frequencyStep)

        while frequency <= min(maxFrequency, sampleRate / 2 - 1) {
            var re = 0.0
            var im = 0.0
            for i in 0..<count {
                let phase = 2 * Double.pi * frequency * Double(i) / sampleRate
                let window = 0.54 - 0.46 * cos(2 * Double.pi * (Double(i) - center) / Double(max(1, count - 1)))
                let value = Double(values[i]) * window
                re += value * cos(phase)
                im -= value * sin(phase)
            }
            candidates.append(SpectralPeak(frequencyHz: frequency, magnitude: sqrt(re * re + im * im)))
            frequency += frequencyStep
        }

        let sorted = candidates.sorted { $0.magnitude > $1.magnitude }
        var selected: [SpectralPeak] = []
        for peak in sorted {
            let separated = selected.allSatisfy { abs($0.frequencyHz - peak.frequencyHz) >= max(70, frequencyStep * 2) }
            if separated { selected.append(peak) }
            if selected.count == peakCount { break }
        }
        return selected.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    public static func hapticEvents(
        samples: [Float],
        sampleRate: Double,
        profile: AudioHapticProfile,
        frameDuration: Double = 0.012,
        safety: HapticSafetyPolicy = .init()
    ) -> [ScheduledHapticEvent] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let frameSize = max(64, Int(sampleRate * frameDuration))
        let hopSize = frameSize
        var events: [ScheduledHapticEvent] = []
        var index = 0

        var maxRMS = 0.000_001
        var rmsValues: [Double] = []
        while index < samples.count {
            let end = min(samples.count, index + frameSize)
            let value = rms(samples[index..<end])
            rmsValues.append(value)
            maxRMS = max(maxRMS, value)
            index += hopSize
        }

        index = 0
        var frameIndex = 0
        while index < samples.count {
            let end = min(samples.count, index + frameSize)
            let slice = samples[index..<end]
            let normalizedLevel = min(1, max(0, rmsValues[frameIndex] / maxRMS))
            if normalizedLevel > 0.015 {
                let peaks: [SpectralPeak]
                switch profile {
                case .rhythm:
                    let zcr = zeroCrossingRate(slice)
                    let frequency = zcr > 0.20 ? 3_600.0 : (zcr > 0.08 ? 1_900.0 : 130.0)
                    peaks = [SpectralPeak(frequencyHz: frequency, magnitude: 1)]
                case .melody:
                    peaks = dominantPeaks(samples: slice, sampleRate: sampleRate, peakCount: 1, frequencyStep: 18)
                case .voice:
                    peaks = dominantPeaks(samples: slice, sampleRate: sampleRate, minFrequency: 180, maxFrequency: 3_600, peakCount: 2, frequencyStep: 28)
                case .fullMix:
                    peaks = dominantPeaks(samples: slice, sampleRate: sampleRate, peakCount: 4, frequencyStep: 32)
                }

                let total = max(0.000_001, peaks.reduce(0) { $0 + $1.magnitude })
                let tones = peaks.map { HapticTone(frequencyHz: $0.frequencyHz, amplitude: $0.magnitude / total) }
                if !tones.isEmpty {
                    let frame = HapticFrame(
                        tones: tones,
                        durationMS: frameDuration * 1_000,
                        level: pow(normalizedLevel, 0.65)
                    )
                    events.append(ScheduledHapticEvent(time: Double(index) / sampleRate, frame: safety.clamp(frame)))
                }
            }
            index += hopSize
            frameIndex += 1
        }
        return events
    }
}
