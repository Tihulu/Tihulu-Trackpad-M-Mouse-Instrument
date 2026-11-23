#if os(macOS)
import Foundation
import NoSpeakerCore

public enum TouchScale: String, CaseIterable, Identifiable, Sendable {
    case chromatic = "Chromatic"
    case major = "Major"
    case minor = "Minor"
    case pentatonic = "Pentatonic"

    public var id: String { rawValue }

    public var intervals: [Int] {
        switch self {
        case .chromatic: return Array(0...24)
        case .major: return [0,2,4,5,7,9,11,12,14,16,17,19,21,23,24]
        case .minor: return [0,2,3,5,7,8,10,12,14,15,17,19,20,22,24]
        case .pentatonic: return [0,2,4,7,9,12,14,16,19,21,24]
        }
    }
}

public struct TouchPerformanceState: Sendable {
    public var contact: TrackpadContact
    public var quantizedMIDI: Int
    public var continuousMIDI: Double
    public var velocity: Int

    public init(contact: TrackpadContact, quantizedMIDI: Int, continuousMIDI: Double, velocity: Int) {
        self.contact = contact
        self.quantizedMIDI = quantizedMIDI
        self.continuousMIDI = continuousMIDI
        self.velocity = velocity
    }
}

public final class TouchInstrumentService: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private var enabled = false
    private var baseMIDINote = 67
    private var scale: TouchScale = .pentatonic
    private var fretless = false
    private var masterLevel = 0.8

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func start(
        baseMIDINote: Int,
        scale: TouchScale,
        fretless: Bool = false,
        masterLevel: Double,
        onPerformance: (@Sendable (TouchPerformanceState) -> Void)? = nil
    ) throws {
        lock.lock()
        self.enabled = true
        self.baseMIDINote = baseMIDINote
        self.scale = scale
        self.fretless = fretless
        self.masterLevel = masterLevel
        lock.unlock()
        try driver.startTouch { [weak self] contact in
            self?.handle(contact, onPerformance: onPerformance)
        }
    }

    public func stop() {
        lock.lock(); enabled = false; lock.unlock()
        driver.stopTouch()
    }

    private func handle(
        _ contact: TrackpadContact,
        onPerformance: (@Sendable (TouchPerformanceState) -> Void)?
    ) {
        lock.lock()
        let active = enabled
        let root = baseMIDINote
        let chosenScale = scale
        let isFretless = fretless
        let levelScale = masterLevel
        lock.unlock()
        guard active else { return }

        let intervals = chosenScale.intervals
        let normalizedX = min(0.9999, max(0, Double(contact.x)))
        let index = min(intervals.count - 1, Int(normalizedX * Double(intervals.count)))
        let quantizedMIDI = min(127, max(0, root + intervals[index]))
        let span = Double(max(1, (intervals.last ?? 24) - (intervals.first ?? 0)))
        let continuousMIDI = min(127, max(0, Double(root) + normalizedX * span))
        let velocity = Int(
            (min(1, max(0.05, 0.25 + Double(contact.size) * 0.75)) * 127).rounded()
        )

        onPerformance?(.init(
            contact: contact,
            quantizedMIDI: quantizedMIDI,
            continuousMIDI: continuousMIDI,
            velocity: velocity
        ))

        guard contact.isDown else { return }

        let baseFrequency: Double
        if isFretless {
            baseFrequency = 440.0 * pow(2.0, (continuousMIDI - 69.0) / 12.0)
        } else {
            guard let frequency = try? MusicTheory.frequency(midi: quantizedMIDI) else { return }
            baseFrequency = frequency
        }

        let vibratoDepth = 0.05 + 0.45 * Double(min(1, max(0, contact.y)))
        let phase = Date().timeIntervalSinceReferenceDate * 6 * 2 * Double.pi
        let frequency = baseFrequency * pow(2, vibratoDepth * sin(phase) / 12)
        let contactLevel = min(1, max(0.35, 0.3 + Double(contact.size) * 0.8)) * levelScale
        let duration = max(1, (0.02 * frequency).rounded()) / frequency * 1_000
        try? driver.play(.init(tones: [.init(frequencyHz: frequency)], durationMS: duration, level: contactLevel))
    }
}
#endif
