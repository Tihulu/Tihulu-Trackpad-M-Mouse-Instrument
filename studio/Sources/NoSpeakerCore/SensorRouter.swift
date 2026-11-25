import Foundation

public enum SensorSource: String, Codable, CaseIterable, Sendable {
    case trackpad, magicMouse, touchBar, lid, camera, microphone, phone, tablet, external, gamepad1, gamepad2
}

/// Adapters normalize physical units and assign the host's monotonic time.
/// No adapter or device is started by constructing a router.
public enum SensorSignal: String, Codable, CaseIterable, Sendable {
    case x, y, contact, contactSize, pressure, angle, speed, gesture, expression
    case airChord1, airChord2, airChord3, airChord4, airChord5
    case airLeftX, airLeftY, airLeftAperture, airLeftPinch, airLeftSpeed
    case airRightX, airRightY, airRightAperture, airRightPinch, airRightSpeed
    case airLeftToggle, airRightToggle
    case airString1_1, airString1_2, airString1_3, airString1_4, airString1_5, airString1_6, airString1_7, airString1_8
    case airString2_1, airString2_2, airString2_3, airString2_4, airString2_5, airString2_6, airString2_7, airString2_8
    case airString3_1, airString3_2, airString3_3, airString3_4, airString3_5, airString3_6, airString3_7, airString3_8
    case airString4_1, airString4_2, airString4_3, airString4_4, airString4_5, airString4_6, airString4_7, airString4_8
    case airString5_1, airString5_2, airString5_3, airString5_4, airString5_5, airString5_6, airString5_7, airString5_8
    case tiltYaw, tiltPitch, tiltRoll, accelerationMagnitude, rotationMagnitude, airStrike
    case drumPad1, drumPad2, drumPad3, drumPad4, drumPad5, drumPad6, drumPad7, drumPad8
    case pianoKey0, pianoKey1, pianoKey2, pianoKey3, pianoKey4, pianoKey5, pianoKey6, pianoKey7, pianoKey8
    case pianoKey9, pianoKey10, pianoKey11, pianoKey12, pianoKey13, pianoKey14, pianoKey15, pianoKey16, pianoKey17
    case pianoKey18, pianoKey19, pianoKey20, pianoKey21, pianoKey22, pianoKey23, pianoKey24
    case pianoSustain
    case pedalExpression, pedalVolume, pedalWah, pedalSustain, pedalSwitch1, pedalSwitch2
    case padA, padB, padX, padY, padLB, padRB, padLT, padRT
    case padUp, padDown, padLeft, padRight, padLSX, padLSY, padRSX, padRSY, padLClick, padRClick
}

public struct SensorCalibration: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var inverted: Bool
    public var deadZone: Double
    public var exponent: Double

    public init(minimum: Double = 0, maximum: Double = 1, inverted: Bool = false,
                deadZone: Double = 0, exponent: Double = 1) {
        self.minimum = minimum
        self.maximum = maximum
        self.inverted = inverted
        self.deadZone = deadZone
        self.exponent = exponent
    }

    public var isValid: Bool {
        minimum.isFinite && maximum.isFinite && (0...1).contains(minimum) &&
        (0...1).contains(maximum) && maximum - minimum >= 0.01 &&
        deadZone.isFinite && (0...0.45).contains(deadZone) &&
        exponent.isFinite && (0.25...4).contains(exponent)
    }

    public func apply(_ input: Double) -> Double? {
        guard isValid, input.isFinite, (0...1).contains(input) else { return nil }
        var value = min(1, max(0, (input - minimum) / (maximum - minimum)))
        if inverted { value = 1 - value }
        // Endpoint dead zone preserves the center of bipolar controls.
        value = min(1, max(0, (value - deadZone) / (1 - 2 * deadZone)))
        return pow(value, exponent)
    }
}

public enum SensorDestinationKind: String, Codable, CaseIterable, Sendable {
    case note, controlChange, pitchBend, sustain
}

/// MIDI channel is zero-based. Note/CC numbers are 0...127.
/// Reserved channel-mode CCs and CC64 are excluded from generic CC routes.
public struct SensorDestination: Codable, Hashable, Sendable {
    public var kind: SensorDestinationKind
    public var channel: Int
    public var number: Int

    public init(_ kind: SensorDestinationKind, channel: Int = 0, number: Int = 0) {
        self.kind = kind
        self.channel = channel
        self.number = number
    }

    public var isValid: Bool {
        guard (0...15).contains(channel) else { return false }
        switch kind {
        case .note: return (0...127).contains(number)
        case .controlChange: return (0...119).contains(number) && number != 64
        case .pitchBend, .sustain: return number == 0
        }
    }

    fileprivate var neutral: Int {
        switch kind {
        case .pitchBend: return 8192
        case .controlChange: return [7, 11].contains(number) ? 127 : 0
        case .note, .sustain: return 0
        }
    }

    fileprivate var isGate: Bool { kind == .note || kind == .sustain }
    fileprivate var sortKey: String { "\(channel):\(kind.rawValue):\(number)" }
}

public struct SensorMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: SensorSource
    public var signal: SensorSignal
    public var destination: SensorDestination
    public var calibration: SensorCalibration
    public var priority: Int
    public var threshold: Double
    public var hysteresis: Double
    public var velocity: Int
    public var response: ContinuousResponse?
    public var pedalMode: GamepadPedalMode?

    public init(id: String, source: SensorSource, signal: SensorSignal,
                destination: SensorDestination, calibration: SensorCalibration = .init(),
                priority: Int = 0, threshold: Double = 0.55,
                hysteresis: Double = 0.08, velocity: Int = 100, response: ContinuousResponse? = nil,
                pedalMode: GamepadPedalMode? = nil) {
        self.id = id
        self.source = source
        self.signal = signal
        self.destination = destination
        self.calibration = calibration
        self.priority = priority
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.velocity = velocity
        self.response = response
        self.pedalMode = pedalMode
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 64 &&
        !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        destination.isValid && calibration.isValid && (-100...100).contains(priority) &&
        threshold.isFinite && (0.05...1).contains(threshold) &&
        hysteresis.isFinite && (0...0.5).contains(hysteresis) && hysteresis < threshold &&
        (1...127).contains(velocity) &&
        (response.map { ContinuousResponse.isContinuous(destination) && $0.isValid } ?? true) &&
        GamepadPedalMode.permits(self)
    }
}

public struct SensorEvent: Sendable {
    public let session: UUID
    public let signal: SensorSignal
    public let value: Double
    public let sequence: UInt64
    public let timestamp: Double

    public init(session: UUID, signal: SensorSignal, value: Double,
                sequence: UInt64, timestamp: Double) {
        self.session = session
        self.signal = signal
        self.value = value
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

/// Values are MIDI data, not wire bytes: note 0 = off, 1...127 = on velocity;
/// sustain 0/127 is CC64, bend 0...16383, other CCs 0...127.
public struct SensorCommand: Equatable, Sendable {
    public let destination: SensorDestination
    public let value: Int
    public init(_ destination: SensorDestination, value: Int) {
        self.destination = destination
        self.value = value
    }
}

public enum SensorRouterError: Error, Equatable {
    case activeSessions, invalidMappings, sessionLimit, invalidTime
}

/// Deterministic single-owner value type. A future adapter must serialize
/// access, translate its clock, authenticate sessions and deliver commands.
/// The core itself has no hardware, network or side effects.
public struct SensorRouter: Sendable {
    private struct Session: Sendable {
        var source: SensorSource
        var sequence: UInt64?
        var timestamp: Double?
        var lastSeen: Double
    }

    private struct Owner: Hashable, Sendable {
        let session: UUID
        let mapping: String
    }

    private struct Contribution: Sendable {
        let owner: Owner
        let destination: SensorDestination
        let priority: Int
        let value: Int
        let filtered: Double
        let timestamp: Double
    }

    public static let maxSessions = 16
    public static let maxMappings = 64
    private struct InputKey: Hashable, Sendable {
        let source: SensorSource
        let signal: SensorSignal
    }

    private var mappings: [SensorMapping] = []
    private var mappingsByInput: [InputKey:[SensorMapping]] = [:]
    private var orderedTargets: [SensorDestination] = []
    private var sessions: [UUID: Session] = [:]
    private var contributions: [Owner: Contribution] = [:]
    private var emitted: [SensorDestination: Int] = [:]
    private var releaseValues: [SensorDestination: Int] = [:]
    private var sharedSwitches: Set<SensorDestination> = []
    private var pedalPressed: Set<Owner> = []
    private var needsReconcile = false

    public init() {}
    public var sessionCount: Int { sessions.count }
    public var mappingCount: Int { mappings.count }

    /// Configuration is atomic and only allowed when all sessions are closed.
    public mutating func configure(_ proposed: [SensorMapping]) throws {
        guard sessions.isEmpty else { throw SensorRouterError.activeSessions }
        guard proposed.count <= Self.maxMappings, proposed.allSatisfy(\.isValid),
              Set(proposed.map(\.id)).count == proposed.count,
              let releases = ContinuousResponse.releaseValues(for: proposed),
              let switches = AirHandsHelper.sharedSwitchTargets(proposed),
              let pedalSwitches = GamepadPedalMode.switchTargets(proposed) else {
            throw SensorRouterError.invalidMappings
        }
        mappings = proposed
        mappingsByInput = Dictionary(grouping:proposed) {
            InputKey(source:$0.source,signal:$0.signal)
        }
        orderedTargets = releases.keys.sorted { $0.sortKey < $1.sortKey }
        releaseValues = releases
        sharedSwitches = switches.union(pedalSwitches)
        pedalPressed.removeAll()
    }

    public mutating func connect(_ source: SensorSource, now: Double) throws -> UUID {
        guard now.isFinite, now >= 0 else { throw SensorRouterError.invalidTime }
        guard sessions.count < Self.maxSessions else { throw SensorRouterError.sessionLimit }
        let id = UUID()
        sessions[id] = Session(source: source, sequence: nil, timestamp: nil, lastSeen: now)
        return id
    }

    /// A heartbeat uses host receipt time, never an untrusted remote clock.
    public mutating func heartbeat(_ id: UUID, now: Double) {
        guard var session = sessions[id], now.isFinite, now >= session.lastSeen else { return }
        session.lastSeen = now
        sessions[id] = session
    }

    public mutating func ingest(_ event: SensorEvent, now: Double) -> [SensorCommand] {
        guard accept(event,now:now) else { return [] }
        return reconcile()
    }

    private mutating func accept(_ event:SensorEvent,now:Double) -> Bool {
        guard var session = sessions[event.session], now.isFinite, now >= session.lastSeen,
              event.timestamp.isFinite, event.timestamp >= 0,
              event.timestamp <= now + 0.02, now - event.timestamp <= 1,
              session.timestamp.map({ event.timestamp >= $0 }) ?? true,
              session.sequence.map({ event.sequence > $0 }) ?? true,
              event.value.isFinite, (0...1).contains(event.value) else { return false }
        session.sequence = event.sequence
        session.timestamp = event.timestamp
        session.lastSeen = now
        sessions[event.session] = session

        for mapping in mappingsByInput[.init(source:session.source,signal:event.signal)] ?? [] {
            guard let normalized = mapping.calibration.apply(event.value) else { continue }
            let owner = Owner(session: event.session, mapping: mapping.id)
            let value: Int
            var filtered = normalized
            if let mode = mapping.pedalMode {
                let wasPressed = pedalPressed.contains(owner)
                let pressed = normalized >= (wasPressed ? mapping.threshold-mapping.hysteresis : mapping.threshold)
                if pressed { pedalPressed.insert(owner) }
                else { pedalPressed.remove(owner) }
                if mode == .toggle {
                    guard pressed && !wasPressed else { continue }
                    value = (contributions[owner]?.value ?? 0) > 0 ? 0 : 127
                } else { value = pressed ? 127 : 0 }
            } else if (mapping.signal == .airStrike || AirStrumPerformance.isStringSignal(mapping.signal)) && mapping.destination.kind == .note {
                // Host onset detector supplies strength; route velocity caps output.
                // No synthetic zero is used for release; remove ownership instead.
                value = event.value > 0 ? max(1, Int((normalized * Double(mapping.velocity)).rounded())) : 0
            } else if mapping.destination.isGate || sharedSwitches.contains(mapping.destination) {
                let wasOn = (contributions[owner]?.value ?? 0) > 0
                let active = normalized >= (wasOn ? mapping.threshold - mapping.hysteresis : mapping.threshold)
                value = active ? (mapping.destination.kind == .note ? mapping.velocity : 127) : 0
            } else {
                let response = mapping.response ?? ContinuousResponse()
                if let previous = contributions[owner] {
                    filtered = response.smooth(normalized, previous: previous.filtered,
                                               elapsed: event.timestamp - previous.timestamp)
                }
                value = response.output(filtered, target: mapping.destination)
            }
            let previous = contributions.updateValue(
                Contribution(owner:owner,destination:mapping.destination,priority:mapping.priority,
                             value:value,filtered:filtered,timestamp:event.timestamp),forKey:owner)
            // Keep smoothing state and the accepted timestamp even when the
            // quantized wire value is unchanged. Only output ownership is dirty.
            if previous?.value != value { needsReconcile = true }
        }
        return true
    }

    /// One camera frame reconciles after all releases and fresh values, so a
    /// pedal transferred between hands does not generate an intermediate off.
    mutating func ingestFrame(session id:UUID,releasing signals:Set<SensorSignal>,events:[SensorEvent],now:Double) -> [SensorCommand] {
        guard let session = sessions[id], now.isFinite, now >= session.lastSeen,
              events.allSatisfy({ $0.session == id && $0.timestamp == now && $0.value.isFinite && (0...1).contains($0.value) }) else { return [] }
        var prior = session.sequence
        for event in events {
            guard prior.map({ event.sequence > $0 }) ?? true else { return [] }
            prior = event.sequence
        }
        guard session.timestamp.map({ now >= $0 }) ?? true else { return [] }
        for signal in signals {
            for mapping in mappingsByInput[.init(source:session.source,signal:signal)] ?? [] {
                let owner = Owner(session:id,mapping:mapping.id)
                pedalPressed.remove(owner)
                if mapping.pedalMode != .toggle { removeContribution(owner) }
            }
        }
        for event in events { _ = accept(event,now:now) }
        return reconcile()
    }

    /// Release an on-screen control without disconnecting its sibling axes.
    /// Remove its contribution instead of feeding a synthetic zero (which
    /// could retrigger an inverted gate or bypass a custom release position).
    public mutating func releaseSignal(session id: UUID, signal: SensorSignal) -> [SensorCommand] {
        releaseSignals(session:id,signals:[signal])
    }

    public mutating func releaseSignals(session id: UUID, signals: Set<SensorSignal>) -> [SensorCommand] {
        guard let session = sessions[id] else { return [] }
        for signal in signals {
            for mapping in mappingsByInput[.init(source:session.source,signal:signal)] ?? [] {
                let owner = Owner(session:id,mapping:mapping.id)
                pedalPressed.remove(owner)
                removeContribution(owner)
            }
        }
        return reconcile()
    }

    /// Closing one device releases only its ownership. Other devices may
    /// continue holding a note, sustain or a shared continuous control.
    public mutating func disconnect(_ id: UUID) -> [SensorCommand] {
        disconnect(sessions:[id])
    }

    /// A departing group is removed before reconciliation. Never restore a
    /// lower-priority owner that is itself part of the same departing group.
    public mutating func disconnect(sessions ids: Set<UUID>) -> [SensorCommand] {
        let removed = ids.intersection(sessions.keys)
        guard !removed.isEmpty else { return [] }
        for id in removed { sessions.removeValue(forKey:id) }
        pedalPressed = pedalPressed.filter { !removed.contains($0.session) }
        let departing = contributions.keys.filter { removed.contains($0.session) }
        for owner in departing { removeContribution(owner) }
        return reconcile()
    }

    /// Caller invokes from its own watchdog. Expiry is atomic across devices.
    public mutating func expire(now: Double, timeout: Double = 2) -> [SensorCommand] {
        guard now.isFinite, timeout.isFinite, (0.1...60).contains(timeout) else { return [] }
        let stale = Set(sessions.compactMap { now - $0.value.lastSeen >= timeout ? $0.key : nil })
        return disconnect(sessions:stale)
    }

    public mutating func panic() -> [SensorCommand] {
        sessions.removeAll()
        pedalPressed.removeAll()
        if !contributions.isEmpty { needsReconcile = true }
        contributions.removeAll()
        return reconcile()
    }

    private mutating func removeContribution(_ owner: Owner) {
        if contributions.removeValue(forKey:owner) != nil { needsReconcile = true }
    }

    private static func precedes(_ a: Contribution, _ b: Contribution) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.owner.mapping != b.owner.mapping { return a.owner.mapping < b.owner.mapping }
        return a.owner.session.uuidString < b.owner.session.uuidString
    }

    private mutating func reconcile() -> [SensorCommand] {
        guard needsReconcile else { return [] }
        needsReconcile = false
        // A single pass selects the same gate maxima and continuous
        // winners as the previous grouped-and-sorted implementation.
        var next: [SensorDestination:Int] = [:]
        var winners: [SensorDestination:Contribution] = [:]
        for contribution in contributions.values {
            let target = contribution.destination
            if target.isGate || sharedSwitches.contains(target) {
                if contribution.value > (next[target] ?? 0) {
                    next[target] = contribution.value
                }
            } else if let previous = winners[target] {
                if Self.precedes(contribution,previous) { winners[target] = contribution }
            } else {
                winners[target] = contribution
            }
        }
        for (target,winner) in winners { next[target] = winner.value }
        var result: [SensorCommand] = []
        // Configuration is frozen while sessions exist, so target order
        // can be computed once without changing emitted command ordering.
        for target in orderedTargets where emitted[target] != nil || next[target] != nil {
            let neutral = releaseValues[target] ?? target.neutral
            let before = emitted[target] ?? neutral
            let after = next[target] ?? neutral
            if target.isGate || sharedSwitches.contains(target) {
                // Shared notes never retrigger when another owner joins.
                if (before > 0) != (after > 0) { result.append(.init(target, value: after)) }
            } else if before != after || (emitted[target] == nil && next[target] != nil) {
                // The receiver may not already be at our neutral value.
                // Send the first owned continuous sample even when neutral.
                result.append(.init(target, value: after))
            }
        }
        emitted = next
        return result
    }
}
