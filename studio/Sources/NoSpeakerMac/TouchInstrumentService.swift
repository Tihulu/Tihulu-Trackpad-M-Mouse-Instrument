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

    private var octaveDegrees: [Int] {
        switch self {
        case .chromatic: return Array(0...11)
        case .major: return [0,2,4,5,7,9,11]
        case .minor: return [0,2,3,5,7,8,10]
        case .pentatonic: return [0,2,4,7,9]
        }
    }

    public func mappedMIDINotes(root: Int, zoneWidth: Double) -> [Int] {
        let safeWidth = min(2.5, max(0.45, zoneWidth))
        let requested = max(3, min(32, Int((Double(intervals.count) / safeWidth).rounded())))
        let degrees = octaveDegrees
        return (0..<requested).compactMap { step in
            let octave = step / degrees.count
            let degree = step % degrees.count
            let note = root + octave * 12 + degrees[degree]
            return note <= 127 ? note : nil
        }
    }
}

public enum TouchSurfaceSelection: String, CaseIterable, Identifiable, Sendable {
    case trackpad = "Trackpad"
    case magicMouse = "Magic Mouse"
    case both = "Both"

    public var id: String { rawValue }

    public func accepts(_ surface: TouchSurfaceKind) -> Bool {
        switch self {
        case .trackpad: return surface == .trackpad
        case .magicMouse: return surface == .magicMouse
        case .both: return true
        }
    }
}

public enum TouchTriggerMode: String, CaseIterable, Identifiable, Sendable {
    case touch = "Touch"
    case press = "Press"

    public var id: String { rawValue }
}

public struct TouchInstrumentConfiguration: Sendable, Equatable {
    public var baseMIDINote: Int
    public var scale: TouchScale
    public var fretless: Bool
    public var zoneWidth: Double
    public var pitchSpanSemitones: Double
    public var surfaceSelection: TouchSurfaceSelection
    public var triggerMode: TouchTriggerMode
    public var pressThreshold: Double
    public var velocityFromPressure: Bool
    public var fixedVelocity: Int
    public var pressureToExpression: Bool
    public var localHapticSound: Bool
    public var masterLevel: Double
    public var trackpadInstrument: SurfaceInstrumentMode
    public var magicMouseInstrument: SurfaceInstrumentMode
    public var trackpadOutput: SurfaceOutputRoute
    public var magicMouseOutput: SurfaceOutputRoute
    public var drumLayout: DrumPadLayout

    public init(
        baseMIDINote: Int = 67,
        scale: TouchScale = .pentatonic,
        fretless: Bool = false,
        zoneWidth: Double = 1,
        pitchSpanSemitones: Double = 24,
        surfaceSelection: TouchSurfaceSelection = .trackpad,
        triggerMode: TouchTriggerMode = .touch,
        pressThreshold: Double = 0.5,
        velocityFromPressure: Bool = true,
        fixedVelocity: Int = 100,
        pressureToExpression: Bool = true,
        localHapticSound: Bool = true,
        masterLevel: Double = 0.8,
        trackpadInstrument: SurfaceInstrumentMode = .melodic,
        magicMouseInstrument: SurfaceInstrumentMode = .melodic,
        trackpadOutput: SurfaceOutputRoute = .both,
        magicMouseOutput: SurfaceOutputRoute = .midiInstrument,
        drumLayout: DrumPadLayout = .standard12
    ) {
        self.baseMIDINote = baseMIDINote
        self.scale = scale
        self.fretless = fretless
        self.zoneWidth = zoneWidth
        self.pitchSpanSemitones = pitchSpanSemitones
        self.surfaceSelection = surfaceSelection
        self.triggerMode = triggerMode
        self.pressThreshold = pressThreshold
        self.velocityFromPressure = velocityFromPressure
        self.fixedVelocity = fixedVelocity
        self.pressureToExpression = pressureToExpression
        self.localHapticSound = localHapticSound
        self.masterLevel = masterLevel
        self.trackpadInstrument = trackpadInstrument
        self.magicMouseInstrument = magicMouseInstrument
        self.trackpadOutput = trackpadOutput
        self.magicMouseOutput = magicMouseOutput
        self.drumLayout = drumLayout
    }

    public func instrument(for surface: TouchSurfaceKind) -> SurfaceInstrumentMode {
        surface == .trackpad ? trackpadInstrument : magicMouseInstrument
    }

    public func output(for surface: TouchSurfaceKind) -> SurfaceOutputRoute {
        surface == .trackpad ? trackpadOutput : magicMouseOutput
    }

    public var selectedSurfaces: [TouchSurfaceKind] {
        TouchSurfaceKind.allCases.filter { surfaceSelection.accepts($0) }
    }

    public var hasMIDIOutput: Bool {
        selectedSurfaces.contains { output(for: $0).sendsMIDI }
    }
}

public struct TouchPerformanceState: Sendable, Equatable, Identifiable {
    public var id: String { "\(surface.rawValue)-\(contactID)" }
    public var contactID: Int
    public var surface: TouchSurfaceKind
    public var isTouching: Bool
    public var isDown: Bool
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var quantizedMIDI: Int
    public var continuousMIDI: Double
    public var velocity: Int
    public var expression: Int
    public var vibrato: Double

    public init(
        contactID: Int,
        surface: TouchSurfaceKind,
        isTouching: Bool,
        isDown: Bool,
        x: Double,
        y: Double,
        pressure: Double,
        quantizedMIDI: Int,
        continuousMIDI: Double,
        velocity: Int,
        expression: Int,
        vibrato: Double
    ) {
        self.contactID = contactID
        self.surface = surface
        self.isTouching = isTouching
        self.isDown = isDown
        self.x = x
        self.y = y
        self.pressure = pressure
        self.quantizedMIDI = quantizedMIDI
        self.continuousMIDI = continuousMIDI
        self.velocity = velocity
        self.expression = expression
        self.vibrato = vibrato
    }
}

public final class TouchInstrumentService: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()

    private var configuration = TouchInstrumentConfiguration()
    private var monitoring = false
    private var active = false
    private var performanceHandler: (@Sendable ([TouchPerformanceState]) -> Void)?
    private var latestStatesBySurface: [TouchSurfaceKind: [TouchPerformanceState]] = [:]

    public init(driver: HapticTrackpadDriver) {
        self.driver = driver
    }

    public func startPreview(
        configuration: TouchInstrumentConfiguration,
        onPerformance: @escaping @Sendable ([TouchPerformanceState]) -> Void
    ) throws {
        lock.lock()
        self.configuration = configuration
        self.performanceHandler = onPerformance
        let needsStart = !monitoring
        monitoring = true
        lock.unlock()

        guard needsStart else { return }

        try driver.startSurfaceMonitoring(includeExternalSurfaces: true) { [weak self] frame in
            self?.handle(frame)
        }
    }

    public func update(configuration: TouchInstrumentConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    public func setActive(_ active: Bool) {
        lock.lock()
        self.active = active
        lock.unlock()
    }

    public func stopPreview() {
        lock.lock()
        monitoring = false
        active = false
        performanceHandler = nil
        latestStatesBySurface.removeAll()
        lock.unlock()
        driver.stopSurfaceMonitoring()
    }

    public func start(
        baseMIDINote: Int,
        scale: TouchScale,
        fretless: Bool = false,
        masterLevel: Double,
        onPerformance: (@Sendable (TouchPerformanceState) -> Void)? = nil
    ) throws {
        let config = TouchInstrumentConfiguration(
            baseMIDINote: baseMIDINote,
            scale: scale,
            fretless: fretless,
            masterLevel: masterLevel
        )
        try startPreview(configuration: config) { states in
            if let first = states.first { onPerformance?(first) }
        }
        setActive(true)
    }

    public func stop() {
        setActive(false)
    }

    private func handle(_ frame: SurfaceTouchFrame) {
        lock.lock()
        let config = configuration
        let isActive = active
        let callback = performanceHandler
        lock.unlock()

        guard config.surfaceSelection.accepts(frame.surface) else { return }

        let mappedNotes = config.scale.mappedMIDINotes(
            root: config.baseMIDINote,
            zoneWidth: config.zoneWidth
        )
        let instrument = config.instrument(for: frame.surface)
        let drumPads = config.drumLayout.pads
        guard !mappedNotes.isEmpty else {
            callback?([])
            return
        }

        let states = frame.contacts.map { contact -> TouchPerformanceState in
            let x = min(0.9999, max(0, Double(contact.x)))
            let y = min(1, max(0, Double(contact.y)))
            let pressure = min(1, max(0, Double(contact.size)))
            let triggered = contact.isDown && (
                config.triggerMode == .touch || pressure >= config.pressThreshold
            )

            let quantized: Int
            if instrument == .drums {
                let padIndex = min(drumPads.count - 1, Int(x * Double(drumPads.count)))
                quantized = drumPads[padIndex].midiNote
            } else {
                let zoneIndex = min(mappedNotes.count - 1, Int(x * Double(mappedNotes.count)))
                quantized = mappedNotes[zoneIndex]
            }
            let continuous = min(
                127,
                max(0, Double(config.baseMIDINote) + x * max(1, config.pitchSpanSemitones))
            )
            let velocity = config.velocityFromPressure
                ? Int((max(0.05, pressure) * 127).rounded())
                : min(127, max(1, config.fixedVelocity))
            let expression = config.pressureToExpression
                ? Int((pressure * 127).rounded())
                : 127

            return TouchPerformanceState(
                contactID: contact.id,
                surface: contact.surface,
                isTouching: contact.isDown,
                isDown: triggered,
                x: x,
                y: y,
                pressure: pressure,
                quantizedMIDI: quantized,
                continuousMIDI: continuous,
                velocity: velocity,
                expression: expression,
                vibrato: y
            )
        }

        lock.lock()
        latestStatesBySurface[frame.surface] = states.filter(\.isTouching)
        let combined = TouchSurfaceKind.allCases
            .filter { config.surfaceSelection.accepts($0) }
            .flatMap { latestStatesBySurface[$0] ?? [] }
        lock.unlock()
        callback?(combined)

        guard isActive, config.localHapticSound,
              config.output(for: frame.surface).sendsHaptics else { return }
        let sounding = states.filter(\.isDown).prefix(6)
        guard !sounding.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var tones: [HapticTone] = []
        var level = 0.0

        for state in sounding {
            let baseFrequency: Double
            if config.fretless && instrument == .melodic {
                baseFrequency = 440.0 * pow(2.0, (state.continuousMIDI - 69.0) / 12.0)
            } else {
                guard let frequency = try? MusicTheory.frequency(midi: state.quantizedMIDI) else { continue }
                baseFrequency = frequency
            }

            let vibratoDepth = 0.5 * state.vibrato
            let vibrato = vibratoDepth * sin(now * 6.0 * 2.0 * Double.pi)
            let frequency = baseFrequency * pow(2.0, vibrato / 12.0)
            tones.append(.init(frequencyHz: frequency))
            level = max(level, Double(state.velocity) / 127.0)
        }

        guard !tones.isEmpty else { return }
        try? driver.play(.init(
            tones: tones,
            durationMS: 28,
            level: min(1, max(0.15, level) * config.masterLevel)
        ))
    }
}
#endif
