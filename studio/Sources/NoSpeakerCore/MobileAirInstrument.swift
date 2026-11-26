import Foundation

/// Projection onto the paired Remote piano and continuous pedal lanes.
public enum MobileAirMode: String, CaseIterable, Identifiable, Sendable {
    case pinchKeys = "Pinch keys"
    case chords = "Two-hand chords"
    case strings = "Air strings"
    case horizontal = "Horizontal helper"
    case vertical = "Vertical helper"
    case aperture = "Aperture helper"
    case speed = "Motion speed helper"
    case pinchHelper = "Pinch helper"
    case toggleHelper = "Pinch toggle helper"
    case depthKeys = "Beam notes"
    case depthControl = "Beam helper"
    public var id: Self { self }
    public var usesDepth: Bool { self == .depthKeys || self == .depthControl }
    public var isHelper: Bool {
        switch self {
        case .horizontal, .vertical, .aperture, .speed, .pinchHelper, .toggleHelper, .depthControl: true
        default: false
        }
    }
}

public struct MobileAirOutput: Equatable, Sendable {
    public var keys: Int = 0
    /// nil releases this control. Zero is a valid active control value.
    public var level: Double?
    public init(keys: Int = 0, level: Double? = nil) { self.keys = keys; self.level = level }
}

public struct MobileAirInstrument: Sendable {
    public static let chordOffsets = [[0,4,7], [2,5,9], [4,7,11], [5,9,12], [7,11,14]]
    public let mode: MobileAirMode
    private let mask: Int
    private let keys: [Int]
    private let near: Double
    private let far: Double
    private var tracking = AirTrackingGate()
    private var chord = AirChordSelection(slots: chordOffsets)!
    private var pinch = AirPinchGate()
    private var strings = AirStringCrossing(stringCount: 3)!
    private var ringing: [Int: Double] = [:]
    private var heldKey: Int?
    private var beamZone: Int?
    private var lastTime: Double?
    private var previous: AirHandSample?
    private var helperPinched = false
    private var helperLatched = false
    private var helperArmed = false

    public init?(mode: MobileAirMode, keys mask: Int, near: Double = 0.25, far: Double = 0.85) {
        guard (0..<(1<<25)).contains(mask), mode.isHelper || mask != 0,
              near.isFinite, far.isFinite, near >= 0.1, far <= 3, far-near >= 0.1 else { return nil }
        let keys = (0..<25).filter { mask & (1 << $0) != 0 }
        if mode == .strings && keys.count < 3 { return nil }
        if mode == .chords && !Self.chordOffsets.contains(where: { notes in notes.allSatisfy { keys.contains($0) } }) { return nil }
        self.mode = mode
        self.keys = keys
        self.mask = mask
        self.near = near
        self.far = far
    }

    private mutating func loseTracking() {
        tracking.reset()
        _ = chord.invalidate()
        pinch.reset()
        strings.reset()
        ringing.removeAll()
        beamZone = nil
        heldKey = nil
        previous = nil
        helperPinched = false; helperLatched = false; helperArmed = false
    }

    /// Independent consumer timer. Never extrapolate a held gesture during silence.
    public mutating func expire(now: Double) -> MobileAirOutput? {
        guard let lastTime else { return .init() }
        guard now.isFinite, now >= lastTime, now-lastTime < 0.15 else {
            loseTracking(); return .init()
        }
        if mode == .strings {
            let before = ringing.count
            ringing = ringing.filter { now < $0.value }
            if before != ringing.count { return .init(keys: ringing.keys.reduce(0) { $0 | (1 << $1) }) }
        }
        return nil
    }

    /// Both Vision and LiDAR belong to the same acquisition. An invalid depth
    /// sample cannot sustain a beam. Lost tracking clears every local gate.
    public mutating func frame(hand: AirHandSample?, fingers: Int? = nil, confidence: Double = 0,
                               depth: Double? = nil, at time: Double, now: Double) -> MobileAirOutput {
        let oldTime = lastTime
        guard time.isFinite, now.isFinite, time >= 0, now >= time, now-time < 0.15,
              oldTime.map({ time > $0 }) ?? true else { loseTracking(); return .init() }
        if let oldTime, time-oldTime >= 0.15 { loseTracking() }
        lastTime = time
        if mode.usesDepth && !(depth.map { $0.isFinite && (near...far).contains($0) } ?? false) {
            loseTracking()
            return .init()
        }
        guard let hand else { loseTracking(); return .init() }
        guard let sample = tracking.accept(hand, at: time, now: now) else { return .init() }
        let prior = previous
        previous = sample
        switch mode {
        case .horizontal: return .init(level: sample.x)
        case .vertical: return .init(level: sample.y)
        case .aperture: return .init(level: sample.aperture)
        case .speed:
            guard let prior, let oldTime else { return .init(level: 0) }
            return .init(level: min(1, hypot(sample.x-prior.x, sample.y-prior.y)/max(0.001,time-oldTime)/5))
        case .pinchHelper, .toggleHelper:
            if sample.aperture >= 0.35 { helperArmed = true; helperPinched = false }
            if helperArmed && !helperPinched && sample.aperture <= 0.18 {
                helperPinched = true; helperLatched.toggle()
            }
            return .init(level: (mode == .pinchHelper ? helperPinched : helperLatched) ? 1 : 0)
        case .depthControl, .depthKeys:
            guard let depth else { return .init() }
            let level = min(1, max(0, (far-depth)/(far-near)))
            if mode == .depthControl { return .init(level: level) }
            let count = min(8, keys.count)
            let position = level * Double(count)
            let proposed = min(count-1, Int(position))
            if let zone = beamZone, position >= Double(zone)-0.15 && position < Double(zone+1)+0.15 {
                return .init(keys: 1 << keys[zone])
            }
            beamZone = proposed
            return .init(keys: 1 << keys[proposed])
        case .pinchKeys:
            if pinch.update(aperture: sample.aperture, selectedSlot: 1) == nil { heldKey = nil; return .init() }
            let key = heldKey ?? keys[min(keys.count-1, Int(sample.x*Double(keys.count)))]
            heldKey = key
            return .init(keys: 1 << key)
        case .chords:
            if chord.observe(count: fingers, confidence: confidence, time: time) == .releaseOwned {
                pinch.reset()
                return .init()
            }
            let selected = chord.selectedSlot == fingers ? chord.selectedSlot : nil
            guard let slot = pinch.update(aperture: sample.aperture, selectedSlot: selected) else { return .init() }
            let notes = Self.chordOffsets[slot-1].reduce(0) { $0 | (1 << $1) }
            return .init(keys: notes & mask == notes ? notes : 0)
        case .strings:
            ringing = ringing.filter { now < $0.value }
            for hit in strings.observe(position: sample.x, time: time) where now < time + 0.12 {
                ringing[keys[hit.string]] = time + 0.12
            }
            return .init(keys: ringing.keys.reduce(0) { $0 | (1 << $1) })
        }
    }
}

/// Convert the upright Vision landmark (lower-left origin) back to the
/// unrotated AR depth map (upper-left origin). Vision receives unmirrored input.
public enum MobileSensorOrientation: CaseIterable, Sendable {
    case up, right, down, left
    public func depthPoint(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        switch self {
        case .up: return (x, 1-y)
        case .right: return (1-y, 1-x)
        case .down: return (1-x, y)
        case .left: return (y, x)
        }
    }

    /// A local 3x3 palm sample must have a majority at a consistent depth.
    public static func palmDepth(_ samples: [(meters: Float, confidence: UInt8)]) -> Double? {
        guard samples.count <= 9 else { return nil }
        let values = samples.filter { (1...2).contains($0.confidence) && $0.meters.isFinite && $0.meters > 0 }
            .map { Double($0.meters) }.sorted()
        guard values.count >= 5 else { return nil }
        let median = values[values.count/2]
        let cluster = values.filter { abs($0-median) <= max(0.03, median*0.08) }
        return cluster.count >= 5 ? cluster[cluster.count/2] : nil
    }
}
