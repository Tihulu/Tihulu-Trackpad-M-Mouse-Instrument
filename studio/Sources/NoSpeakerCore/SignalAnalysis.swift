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
        guard (16...65_536).contains(samples.count),
              sampleRate.isFinite,(1...192_000).contains(sampleRate),
              minFrequency.isFinite,maxFrequency.isFinite,frequencyStep.isFinite,
              minFrequency > 0,maxFrequency >= minFrequency,frequencyStep >= 1,
              (1...64).contains(peakCount),samples.allSatisfy(\.isFinite) else { return [] }
        let lower = max(minFrequency,frequencyStep)
        let upper = min(maxFrequency,sampleRate/2-1)
        guard lower <= upper,(upper-lower)/frequencyStep <= 2047 else { return [] }
        let count = samples.count
        let mean = samples.reduce(0.0) { $0+Double($1) } / Double(count)
        // Correct Hamming orientation: low at edges, high in the center.
        // Precompute once; arbitrary-frequency Goertzel recurrence avoids
        // two trigonometric evaluations per sample per spectral candidate.
        let values = samples.enumerated().map { i,value in
            (Double(value)-mean)*(0.54-0.46*cos(2*Double.pi*Double(i)/Double(count-1)))
        }
        var candidates:[SpectralPeak] = []
        let binCount = Int((upper-lower)/frequencyStep)+1
        candidates.reserveCapacity(binCount)
        for bin in 0..<binCount {
            let frequency = lower+Double(bin)*frequencyStep
            let coefficient = 2*cos(2*Double.pi*frequency/sampleRate)
            var previous = 0.0, prior = 0.0
            for value in values {
                let next = value+coefficient*previous-prior
                prior=previous;previous=next
            }
            let power = max(0,previous*previous+prior*prior-coefficient*previous*prior)
            if power.isFinite && power > 1e-18 {
                candidates.append(.init(frequencyHz:frequency,magnitude:sqrt(power)))
            }
        }

        let sorted = candidates.sorted {
            $0.magnitude == $1.magnitude ? $0.frequencyHz < $1.frequencyHz : $0.magnitude > $1.magnitude
        }
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
        (try? render(samples:samples,sampleRate:sampleRate,profile:profile,
                     frameDuration:frameDuration,safety:safety,cancellation:nil)) ?? []
    }

    public static func hapticEvents(
        samples:[Float],sampleRate:Double,profile:AudioHapticProfile,
        frameDuration:Double = 0.012,safety:HapticSafetyPolicy = .init(),
        cancellation:VoiceRenderCancellation
    ) throws -> [ScheduledHapticEvent] {
        try render(samples:samples,sampleRate:sampleRate,profile:profile,
                   frameDuration:frameDuration,safety:safety,cancellation:cancellation)
    }

    private static func render(samples:[Float],sampleRate:Double,profile:AudioHapticProfile,
                               frameDuration:Double,safety:HapticSafetyPolicy,
                               cancellation:VoiceRenderCancellation?) throws -> [ScheduledHapticEvent] {
        try cancellation?.check()
        guard sampleRate.isFinite,(1...192_000).contains(sampleRate),
              frameDuration.isFinite,(0.0005...0.12).contains(frameDuration),
              !samples.isEmpty else { return [] }
        let frameSize = max(64, Int(sampleRate * frameDuration))
        let hopSize = frameSize
        var events: [ScheduledHapticEvent] = []
        var index = 0

        var maxRMS = 0.000_001
        var rmsValues: [Double] = []
        while index < samples.count {
            let end = min(samples.count, index + frameSize)
            try cancellation?.check()
            let slice = samples[index..<end]
            guard slice.allSatisfy(\.isFinite) else { return [] }
            let mean = slice.reduce(0.0) { $0+Double($1) }/Double(slice.count)
            let value = sqrt(slice.reduce(0.0) {
                let centered = Double($1)-mean
                return $0+centered*centered
            }/Double(slice.count))
            rmsValues.append(value)
            maxRMS = max(maxRMS, value)
            index += hopSize
        }

        index = 0
        var frameIndex = 0
        while index < samples.count {
            let end = min(samples.count, index + frameSize)
            try cancellation?.check()
            let raw = samples[index..<end]
            let mean = raw.reduce(0.0) { $0+Double($1) }/Double(raw.count)
            let centered = raw.map { Float(Double($0)-mean) }
            let slice = centered[...]
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
        try cancellation?.check()
        return events
    }
}
