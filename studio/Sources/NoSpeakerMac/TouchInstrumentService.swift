#if os(macOS)
import Foundation
import NoSpeakerCore

public enum TouchScale: String, CaseIterable, Identifiable, Sendable, Codable {
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
        guard (0...127).contains(root), zoneWidth.isFinite else { return [] }
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

public enum TouchSurfaceSelection: String, CaseIterable, Identifiable, Sendable, Codable {
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

public enum TouchTriggerMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case touch = "Touch"
    case press = "Press"

    public var id: String { rawValue }
}

public struct TouchInstrumentConfiguration: Sendable, Equatable {
    public var baseMIDINote: Int
    public var scale: TouchScale
    public var customScale: CustomScale?
    public var physicalChordBank: ChordBank?
    public var stringLayout: StringSurfaceLayout
    public var mouseStringLayout: StringSurfaceLayout?
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
    public var magicMouseOrientation: SurfaceOrientation

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
        trackpadOutput: SurfaceOutputRoute = .trackpadHaptic,
        magicMouseOutput: SurfaceOutputRoute = .midiInstrument,
        drumLayout: DrumPadLayout = .standard12,
        magicMouseOrientation: SurfaceOrientation = .horizontal,
        customScale: CustomScale? = nil,
        physicalChordBank: ChordBank? = nil,
        stringLayout: StringSurfaceLayout = .init(),
        mouseStringLayout: StringSurfaceLayout? = nil
    ) {
        self.baseMIDINote = baseMIDINote
        self.scale = scale
        self.customScale = customScale
        self.physicalChordBank = physicalChordBank
        self.stringLayout = stringLayout
        self.mouseStringLayout = mouseStringLayout
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
        self.magicMouseOrientation = magicMouseOrientation
    }

    public func strings(for surface: TouchSurfaceKind) -> StringSurfaceLayout {
        surface == .magicMouse ? (mouseStringLayout ?? stringLayout) : stringLayout
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

    // Volume-only changes do not discard held voices. All other changes
    // conservatively invalidate old mapped states and pending percussion.
    func requiresHapticReset(comparedTo previous: Self) -> Bool {
        var old = previous
        old.masterLevel = masterLevel
        return old != self
    }

    public var hasValidSampleDomain: Bool {
        TouchSampleDomain.validConfiguration(root:baseMIDINote,width:zoneWidth,span:pitchSpanSemitones,
                                             threshold:pressThreshold,level:masterLevel)
    }

    public var mappedMIDINotes: [Int] {
        guard hasValidSampleDomain else { return [] }
        if !fretless, let customScale {
            return customScale.mappedMIDINotes(root: baseMIDINote, zoneWidth: zoneWidth)
        }
        return scale.mappedMIDINotes(root: baseMIDINote, zoneWidth: zoneWidth)
    }

    public var permitsMelodicMIDI: Bool {
        guard !fretless, let customScale else { return true }
        guard customScale.isValid else { return false }
        let sendsMelodicMIDI = selectedSurfaces.contains {
            instrument(for: $0) == .melodic && output(for: $0).sendsMIDI
        }
        return !sendsMelodicMIDI || !customScale.isMicrotonal || customScale.allowEqualTemperedMIDI
    }

    public func frettedFrequency(midi: Int) -> Double? {
        if let customScale {
            return customScale.tunedFrequency(midi: midi, root: baseMIDINote)
        }
        return try? MusicTheory.frequency(midi: midi)
    }

    public func permitsStringMIDI(isMPE:Bool) -> Bool {
        let stringSurfaces = selectedSurfaces.filter { instrument(for:$0).isStringSurface && output(for:$0).sendsMIDI }
        guard !stringSurfaces.isEmpty else { return true }
        if stringSurfaces.contains(where: { instrument(for:$0) == .fretlessStrings }) && !isMPE { return false }
        let mixedFretless = fretless && selectedSurfaces.contains {
            instrument(for:$0) == .melodic && output(for:$0).sendsMIDI
        }
        return stringSurfaces.allSatisfy { strings(for:$0).permitsMIDI(mixedFretless:mixedFretless,isMPE:isMPE) }
    }

    public var hasPhysicalChords: Bool {
        selectedSurfaces.contains { instrument(for:$0) == .chords }
    }
    public func permitsPhysicalChordMIDI(isMPE: Bool) -> Bool {
        guard selectedSurfaces.contains(where: { instrument(for:$0) == .chords && output(for:$0).sendsMIDI }) else { return true }
        guard let bank = physicalChordBank else { return false }
        let mixedFretless = fretless && selectedSurfaces.contains {
            instrument(for:$0) == .melodic && output(for:$0).sendsMIDI
        }
        return PhysicalChordGrid.permitsMIDI(bank:bank,isMPE:isMPE,mixedFretless:mixedFretless)
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
    public var chordSlot: Int? = nil
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
    private var sampleRevision: UInt64 = 0
    private var renderRevision: UInt64 = 0
    private var frameSequence: UInt64 = 0
    private var publicationSequence: UInt64 = 0
    private var lastFrameBySurface: [TouchSurfaceKind:UInt64] = [:]
    private var monitoring = false
    private var monitoringToken: UUID?
    private var patchMailbox: PatchSurfaceMailbox?
    private var active = false
    private var performanceHandler: (@Sendable ([TouchPerformanceState],TouchSnapshotStamp) -> Void)?
    private var latestStatesBySurface: [TouchSurfaceKind: [TouchPerformanceState]] = [:]
    private var liveHapticStates: [TouchPerformanceState] = []
    private var sustainedHapticStates = HapticSustainVoices<TouchPerformanceState>()
    private var sustainActive = false
    private var activeDrumContacts: Set<String> = []
    // Grid strikes survive sample-publication invalidation, but never a
    // structural layout change or an explicit performance stop.
    private var gridDrumNotes: [TouchSurfaceKind: [Int: Int]] = [:]
    private var chordSlots: [TouchSurfaceKind: [Int: Int]] = [:]
    private var pendingDrumHits: [HapticFrame] = []
    // Accessed only on the serial render queue.
    private var drumPriorityUntil = 0.0
    private var drumRenderToken: UUID?
    private var drumRenderRevision: UInt64?
    private var renderTimer: DispatchSourceTimer?
    private let renderFence = HapticSourceFence()
    private let renderQueue = DispatchQueue(
        label: "com.tihulu.nospeaker.touch-haptic-render",
        qos: .userInteractive
    )

    public init(driver: HapticTrackpadDriver) {
        self.driver = driver
    }

    public func startPreview(
        configuration: TouchInstrumentConfiguration,
        onPerformance: @escaping @Sendable ([TouchPerformanceState]) -> Void
    ) throws {
        try startStampedPreview(configuration:configuration) { states,_ in onPerformance(states) }
    }

    public func startStampedPreview(configuration: TouchInstrumentConfiguration,
        onPerformance: @escaping @Sendable ([TouchPerformanceState],TouchSnapshotStamp) -> Void) throws {
        lock.lock()
        let changed = applyConfigurationLocked(configuration)
        self.performanceHandler = onPerformance
        let needsStart = !monitoring
        let token = needsStart ? UUID() : monitoringToken
        monitoringToken = token
        monitoring = true
        lock.unlock()
        if changed { renderFence.drain() }

        guard needsStart, let token else { return }

        do {
            try driver.startSurfaceMonitoring(includeExternalSurfaces: true) { [weak self] frame in
                self?.handle(frame, token: token)
            }
        } catch {
            lock.lock()
            if monitoringToken == token {
                monitoring = false
                monitoringToken = nil
                performanceHandler = nil
                latestStatesBySurface.removeAll()
            }
            lock.unlock()
            throw error
        }
    }

    /// A per-run bounded raw-frame subscriber. Does not register another
    /// private callback or alter Touch Instrument rendering.
    public func setPatchMailbox(_ mailbox: PatchSurfaceMailbox?) {
        lock.lock()
        patchMailbox = mailbox
        lock.unlock()
    }

    public func update(configuration: TouchInstrumentConfiguration) {
        lock.lock()
        let changed = applyConfigurationLocked(configuration)
        lock.unlock()
        // Never hold the state lock while draining the source fence.
        if changed { renderFence.drain() }
    }

    // Caller holds lock. Invalid settings cannot retain old cached notes.
    private func applyConfigurationLocked(_ next: TouchInstrumentConfiguration) -> Bool {
        let changed = configuration != next
        if changed {
            invalidateSamplesLocked()
            renderRevision &+= 1
        }
        if next.requiresHapticReset(comparedTo:configuration) ||
            !next.hasValidSampleDomain || next.mappedMIDINotes.isEmpty {
            latestStatesBySurface.removeAll()
            liveHapticStates.removeAll()
            sustainedHapticStates.removeAll()
            activeDrumContacts.removeAll()
            gridDrumNotes.removeAll()
            chordSlots.removeAll()
            pendingDrumHits.removeAll()
            sustainActive = false
        }
        configuration = next
        return changed
    }

    public var currentSampleRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return sampleRevision
    }

    public func invalidatePendingSamples() {
        lock.lock(); defer { lock.unlock() }
        invalidateSamplesLocked()
    }

    private func invalidateSamplesLocked() {
        sampleRevision &+= 1
        latestStatesBySurface.removeAll()
        lastFrameBySurface.removeAll()
    }

    public func setActive(_ active: Bool) {
        if !active { renderFence.revoke() }
        lock.lock()
        if self.active != active {
            invalidateSamplesLocked()
            gridDrumNotes.removeAll()
            chordSlots.removeAll()
            renderRevision &+= 1
        }
        self.active = active
        if !active {
            sustainActive = false
            liveHapticStates.removeAll()
            sustainedHapticStates.removeAll()
            activeDrumContacts.removeAll()
            gridDrumNotes.removeAll()
            chordSlots.removeAll()
            pendingDrumHits.removeAll()
        }
        lock.unlock()

        if active {
            guard renderTimer == nil else { return }
            let token = renderFence.begin()
            let timer = DispatchSource.makeTimerSource(queue: renderQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(18), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.renderHapticFrame(token: token) }
            renderTimer = timer
            timer.resume()
        } else {
            renderTimer?.cancel()
            renderTimer = nil
        }
    }

    /// Holds already triggered local haptic notes when sustain is active.
    /// The output timer, not a touch callback, keeps the motor refreshed after
    /// the last finger lifts. No playback is performed while Preview is idle.
    public func setSustainActive(_ isOn: Bool) {
        lock.lock()
        let changed = sustainActive != isOn
        if changed { renderRevision &+= 1 }
        sustainActive = isOn
        if isOn {
            for state in liveHapticStates where configuration.output(for: state.surface).sendsHaptics && configuration.instrument(for: state.surface) != .drums {
                sustainedHapticStates.remember(id:state.id,value:state)
            }
        } else {
            sustainedHapticStates.removeAll()
        }
        lock.unlock()
        if changed && !isOn { renderFence.drain() }
    }

    public func stopPreview() {
        setActive(false)
        lock.lock()
        monitoring = false
        monitoringToken = nil
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

    private func handle(_ frame: SurfaceTouchFrame, token: UUID) {
        lock.lock()
        guard monitoring, monitoringToken == token else { lock.unlock(); return }
        let config = configuration
        let revision = sampleRevision
        frameSequence &+= 1
        let frameID = frameSequence
        let isActive = active
        let callback = performanceHandler
        // Submit under the subscription lock to serialize detachment with
        // the bounded enqueue; no MIDI or actor dispatch in the subscriber.
        patchMailbox?.submit(frame)
        lock.unlock()

        guard config.surfaceSelection.accepts(frame.surface) else { return }

        let mappedNotes = config.mappedMIDINotes
        let instrument = config.instrument(for: frame.surface)
        var states: [TouchPerformanceState] = mappedNotes.isEmpty ? [] : frame.contacts.compactMap { contact -> TouchPerformanceState? in
            guard contact.surface == frame.surface,
                  let sample = TouchSampleDomain.normalize(x:Double(contact.x),y:Double(contact.y),pressure:Double(contact.size)) else { return nil }
            let rawX = sample.x
            let rawY = sample.y
            let (x, y) = contact.surface == .magicMouse
                ? config.magicMouseOrientation.transformed(x: rawX, y: rawY)
                : (rawX, rawY)
            let pressure = sample.pressure
            let triggered = contact.isDown && (
                config.triggerMode == .touch || pressure >= config.pressThreshold
            )

            let quantized: Int
            var stringPitch: Double? = nil
            var chordSlot: Int? = nil
            if instrument == .fretlessStrings {
                guard let cell = config.strings(for:frame.surface).continuousCell(x:x,y:y) else { return nil }
                stringPitch = cell.pitch
                quantized = Int(cell.pitch.rounded())
            } else if instrument == .guitar {
                guard let cell = config.strings(for:frame.surface).cell(x:x,y:y) else { return nil }
                quantized = cell.note
            } else if instrument == .chords {
                guard let slot = PhysicalChordGrid.slot(x:x,y:y),
                      let pad = config.physicalChordBank?.pad(at:slot), let first = pad.notes.first else { return nil }
                chordSlot = slot
                quantized = first
            } else if instrument == .drums {
                guard let pad = config.drumLayout.pad(x:x,y:y) else { return nil }
                quantized = pad.midiNote
            } else {
                let zoneIndex = min(mappedNotes.count - 1, Int(x * Double(mappedNotes.count)))
                quantized = mappedNotes[zoneIndex]
            }
            let continuous = stringPitch ?? min(
                127,
                max(0, Double(config.baseMIDINote) + x * max(1, config.pitchSpanSemitones))
            )
            let velocity = config.velocityFromPressure
                ? Int((max(0.05, pressure) * 127).rounded())
                : min(127, max(1, config.fixedVelocity))
            let expression = config.pressureToExpression
                ? Int((pressure * 127).rounded())
                : 127

            var state = TouchPerformanceState(
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
            state.chordSlot = chordSlot
            return state
        }

        lock.lock()
        guard monitoring, monitoringToken == token, sampleRevision == revision,
              frameID > (lastFrameBySurface[frame.surface] ?? 0) else { lock.unlock(); return }
        lastFrameBySurface[frame.surface] = frameID
        publicationSequence &+= 1
        let stamp = TouchSnapshotStamp(revision:revision,sequence:publicationSequence)
        if instrument == .drums && config.drumLayout.isGrid {
            let previous = gridDrumNotes[frame.surface] ?? [:]
            var next: [Int: Int] = [:]
            for index in states.indices where states[index].isDown {
                let id = states[index].contactID
                states[index].quantizedMIDI = config.drumLayout.strikeNote(
                    at:states[index].quantizedMIDI, previousDownNote:previous[id])
                next[id] = states[index].quantizedMIDI
            }
            gridDrumNotes[frame.surface] = next
        }
        if instrument == .chords {
            let previous = chordSlots[frame.surface] ?? [:]
            var next: [Int:Int] = [:]
            for index in states.indices where states[index].isDown {
                let id = states[index].contactID
                guard let slot = previous[id] ?? states[index].chordSlot,
                      let pad = config.physicalChordBank?.pad(at:slot), let first = pad.notes.first else {
                    states[index].isDown = false
                    continue
                }
                states[index].chordSlot = slot
                states[index].quantizedMIDI = first
                next[id] = slot
            }
            chordSlots[frame.surface] = next
        }
        latestStatesBySurface[frame.surface] = states.filter(\.isTouching)
        let combined = TouchSurfaceKind.allCases
            .filter { config.surfaceSelection.accepts($0) }
            .flatMap { latestStatesBySurface[$0] ?? [] }
        // Commit the haptic snapshot under the same lock as publication.
        // A preview is never a percussion trigger.
        guard isActive && active else {
            lock.unlock()
            callback?(combined,stamp)
            return
        }
        let liveConfig = configuration
        liveHapticStates = combined.filter { $0.isDown }
        let drums = liveHapticStates.filter {
            liveConfig.localHapticSound &&
            liveConfig.output(for: $0.surface).sendsHaptics &&
            liveConfig.instrument(for: $0.surface) == .drums
        }
        for state in drums where !activeDrumContacts.contains(state.id) {
            if pendingDrumHits.count < 16,
               let hit = HapticPatternRenderer.drumFrame(
                   midiNote: state.quantizedMIDI, velocity: Double(state.velocity) / 127
               ) {
                pendingDrumHits.append(hit)
            }
        }
        activeDrumContacts = Set(drums.map(\.id))
        if sustainActive {
            for state in liveHapticStates where liveConfig.output(for: state.surface).sendsHaptics && liveConfig.instrument(for: state.surface) != .drums {
                sustainedHapticStates.remember(id:state.id,value:state)
            }
        }
        lock.unlock()
        callback?(combined,stamp)
    }

    private func renderHapticFrame(token: UUID) {
        var snapshot: (TouchInstrumentConfiguration, [TouchPerformanceState],
                        HapticSustainVoices<TouchPerformanceState>, Bool, [HapticFrame], UInt64)?
        renderFence.submit(token) {
            lock.lock()
            defer { lock.unlock() }
            guard active && configuration.localHapticSound else { return }
            snapshot = (configuration, liveHapticStates, sustainedHapticStates,
                        sustainActive, pendingDrumHits, renderRevision)
            pendingDrumHits.removeAll(keepingCapacity: true)
        }
        guard let (config, current, sustained, isSustained, hits, revision) = snapshot else { return }
        if drumRenderToken != token || drumRenderRevision != revision {
            drumRenderToken = token
            drumRenderRevision = revision
            drumPriorityUntil = 0
        }

        let now = ProcessInfo.processInfo.systemUptime
        if !hits.isEmpty {
            for hit in hits {
                guard submitFrame(hit, level: config.masterLevel, token: token, revision:revision) else { return }
            }
            drumPriorityUntil = now + (hits.map(\.durationMS).max() ?? 0) / 1000
            return
        }
        // The motor is shared; give a one-shot drum its nominal duration
        // before refreshing a continuous melodic voice.
        guard now >= drumPriorityUntil else { return }

        let sounding = sustained.sounding(
            live:current.map { (id:$0.id,value:$0) },
            includeSustained:isSustained
        ) { state in
            config.output(for:state.surface).sendsHaptics &&
            config.instrument(for:state.surface) != .drums
        }
        guard !sounding.isEmpty else { return }

        var tones: [HapticTone] = []
        var chordFrequencies = Set<Double>()
        var level = 0.0
        for state in sounding {
            if config.instrument(for:state.surface) == .chords {
                guard let slot = state.chordSlot, let bank = config.physicalChordBank,
                      let pad = bank.pad(at:slot) else { continue }
                for note in pad.notes {
                    let frequency = bank.customScale?.tunedFrequency(midi:note,root:bank.root) ?? (try? MusicTheory.frequency(midi:note))
                    if let frequency, chordFrequencies.insert(frequency).inserted {
                        tones.append(.init(frequencyHz:frequency))
                    }
                }
                level = max(level,Double(state.velocity)/127)
                continue
            }
            let baseFrequency: Double
            if config.instrument(for:state.surface) == .fretlessStrings ||
                (config.fretless && config.instrument(for: state.surface) == .melodic) {
                baseFrequency = 440.0 * pow(2.0, (state.continuousMIDI - 69.0) / 12.0)
            } else if config.instrument(for:state.surface) == .guitar {
                guard let frequency = try? MusicTheory.frequency(midi:state.quantizedMIDI) else { continue }
                baseFrequency = frequency
            } else {
                guard let frequency = config.frettedFrequency(midi: state.quantizedMIDI) else {
                    continue
                }
                baseFrequency = frequency
            }
            // Y selects the string; it must not simultaneously add vibrato.
            let vibrato = config.instrument(for:state.surface).isStringSurface ? 0 : 0.5 * state.vibrato * sin(now * 6 * 2 * Double.pi)
            tones.append(.init(frequencyHz: baseFrequency * pow(2, vibrato / 12)))
            level = max(level, Double(state.velocity) / 127)
        }

        guard !tones.isEmpty else { return }
        submitFrame(.init(
            tones: tones,
            durationMS: 28,
            level: min(1, max(0.15, level) * config.masterLevel)
        ), level: 1, token: token, revision:revision)
    }

    @discardableResult
    private func submitFrame(_ frame: HapticFrame, level: Double, token: UUID, revision: UInt64) -> Bool {
        var submitted = false
        renderFence.submit(token) {
            lock.lock()
            let allowed = active && configuration.localHapticSound && renderRevision == revision
            lock.unlock()
            guard allowed else { return }
            do {
                try driver.play(frame, masterLevel: level)
                submitted = true
            } catch { return }
        }
        return submitted
    }
}
#endif
