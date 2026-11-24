import Foundation

public enum SensorSource: String, Codable, CaseIterable, Sendable {
    case trackpad, magicMouse, touchBar, lid, camera, microphone, phone, tablet, external
}

/// Adapters normalize physical units and assign the host's monotonic time.
/// No adapter or device is started by constructing a router.
public enum SensorSignal: String, Codable, CaseIterable, Sendable {
    case x, y, contact, contactSize, pressure, angle, speed, gesture, expression
    case airChord1, airChord2, airChord3, airChord4, airChord5
    case tiltYaw, tiltPitch, tiltRoll, accelerationMagnitude, rotationMagnitude, airStrike
    case drumPad1, drumPad2, drumPad3, drumPad4, drumPad5, drumPad6, drumPad7, drumPad8
    case pianoKey0, pianoKey1, pianoKey2, pianoKey3, pianoKey4, pianoKey5, pianoKey6, pianoKey7, pianoKey8
    case pianoKey9, pianoKey10, pianoKey11, pianoKey12, pianoKey13, pianoKey14, pianoKey15, pianoKey16, pianoKey17
    case pianoKey18, pianoKey19, pianoKey20, pianoKey21, pianoKey22, pianoKey23, pianoKey24
    case pianoSustain
    case pedalExpression, pedalVolume, pedalWah, pedalSustain, pedalSwitch1, pedalSwitch2
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

    public init(id: String, source: SensorSource, signal: SensorSignal,
                destination: SensorDestination, calibration: SensorCalibration = .init(),
                priority: Int = 0, threshold: Double = 0.55,
                hysteresis: Double = 0.08, velocity: Int = 100, response: ContinuousResponse? = nil) {
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
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 64 &&
        !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        destination.isValid && calibration.isValid && (-100...100).contains(priority) &&
        threshold.isFinite && (0.05...1).contains(threshold) &&
        hysteresis.isFinite && (0...0.5).contains(hysteresis) && hysteresis < threshold &&
        (1...127).contains(velocity) &&
        (response.map { ContinuousResponse.isContinuous(destination) && $0.isValid } ?? true)
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
    private var mappings: [SensorMapping] = []
    private var sessions: [UUID: Session] = [:]
    private var contributions: [Owner: Contribution] = [:]
    private var emitted: [SensorDestination: Int] = [:]
    private var releaseValues: [SensorDestination: Int] = [:]

    public init() {}
    public var sessionCount: Int { sessions.count }
    public var mappingCount: Int { mappings.count }

    /// Configuration is atomic and only allowed when all sessions are closed.
    public mutating func configure(_ proposed: [SensorMapping]) throws {
        guard sessions.isEmpty else { throw SensorRouterError.activeSessions }
        guard proposed.count <= Self.maxMappings, proposed.allSatisfy(\.isValid),
              Set(proposed.map(\.id)).count == proposed.count,
              let releases = ContinuousResponse.releaseValues(for: proposed) else {
            throw SensorRouterError.invalidMappings
        }
        mappings = proposed
        releaseValues = releases
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
        guard var session = sessions[event.session], now.isFinite, now >= session.lastSeen,
              event.timestamp.isFinite, event.timestamp >= 0,
              event.timestamp <= now + 0.02, now - event.timestamp <= 1,
              session.timestamp.map({ event.timestamp >= $0 }) ?? true,
              session.sequence.map({ event.sequence > $0 }) ?? true,
              event.value.isFinite, (0...1).contains(event.value) else { return [] }
        session.sequence = event.sequence
        session.timestamp = event.timestamp
        session.lastSeen = now
        sessions[event.session] = session

        for mapping in mappings where mapping.source == session.source && mapping.signal == event.signal {
            guard let normalized = mapping.calibration.apply(event.value) else { continue }
            let owner = Owner(session: event.session, mapping: mapping.id)
            let value: Int
            var filtered = normalized
            if mapping.signal == .airStrike && mapping.destination.kind == .note {
                // Host onset detector supplies strength; route velocity caps output.
                // No synthetic zero is used for release; remove ownership instead.
                value = event.value > 0 ? max(1, Int((normalized * Double(mapping.velocity)).rounded())) : 0
            } else if mapping.destination.isGate {
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
            contributions[owner] = Contribution(owner: owner, destination: mapping.destination,
                                                priority: mapping.priority, value: value,
                                                filtered: filtered, timestamp: event.timestamp)
        }
        return reconcile()
    }

    /// Release an on-screen control without disconnecting its sibling axes.
    /// Remove its contribution instead of feeding a synthetic zero (which
    /// could retrigger an inverted gate or bypass a custom release position).
    public mutating func releaseSignal(session id: UUID, signal: SensorSignal) -> [SensorCommand] {
        guard let session = sessions[id] else { return [] }
        let ids = Set(mappings.filter { $0.source == session.source && $0.signal == signal }.map(\.id))
        contributions = contributions.filter { $0.key.session != id || !ids.contains($0.key.mapping) }
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
        contributions = contributions.filter { !removed.contains($0.key.session) }
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
        contributions.removeAll()
        return reconcile()
    }

    private mutating func reconcile() -> [SensorCommand] {
        let grouped = Dictionary(grouping: contributions.values, by: \.destination)
        var next: [SensorDestination: Int] = [:]
        for (target, owners) in grouped {
            if target.isGate {
                let level = owners.map(\.value).max() ?? 0
                if level > 0 { next[target] = level }
            } else {
                // Higher priority wins. Stable route ID, then session ID break ties.
                let winner = owners.sorted { a, b in
                    if a.priority != b.priority { return a.priority > b.priority }
                    if a.owner.mapping != b.owner.mapping { return a.owner.mapping < b.owner.mapping }
                    return a.owner.session.uuidString < b.owner.session.uuidString
                }.first
                if let winner { next[target] = winner.value }
            }
        }
        let targets = Set(emitted.keys).union(next.keys).sorted { $0.sortKey < $1.sortKey }
        var result: [SensorCommand] = []
        for target in targets {
            let neutral = releaseValues[target] ?? target.neutral
            let before = emitted[target] ?? neutral
            let after = next[target] ?? neutral
            if target.isGate {
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
