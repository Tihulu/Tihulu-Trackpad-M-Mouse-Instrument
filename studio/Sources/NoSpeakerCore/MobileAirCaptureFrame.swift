import Foundation

/// Derived observations only; neither images nor depth maps cross this boundary.
public struct MobileAirObservation: Sendable {
    public let sample: AirHandSample?
    public let fingers: Int?
    public let confidence: Double
    public let depth: Double?
    public init(sample: AirHandSample?, fingers: Int? = nil, confidence: Double = 0, depth: Double? = nil) {
        self.sample = sample; self.fingers = fingers; self.confidence = confidence; self.depth = depth
    }
}

public struct MobileAirCaptureFrame: Sendable {
    public let single: MobileAirObservation?
    public let left: MobileAirObservation?
    public let right: MobileAirObservation?
    public let time: Double
    /// AVFoundation / ARKit host uptime expressed in the sender's nanoseconds.
    public static func nanoseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int64(exactly: (seconds * 1_000_000_000).rounded(.down))
    }

    public init(single: MobileAirObservation? = nil, left: MobileAirObservation? = nil,
                right: MobileAirObservation? = nil, time: Double) {
        self.single = single; self.left = left; self.right = right; self.time = time
    }
}

public enum MobileAirHandRole: String, CaseIterable, Identifiable, Sendable {
    case single, left, right
    public var id: String { rawValue }
}

/// Per-mode acquisition projection. Two-hand chords require distinct observed
/// left/right hands; no single-hand substitution on tracking loss.
public struct MobileAirCaptureProjection: Sendable {
    public let role: MobileAirHandRole
    public let orientation: AirControlOrientation
    public let mirrorX: Bool
    private var engine: MobileAirInstrument

    public init?(mode: MobileAirMode, keys: Int, role: MobileAirHandRole = .single,
                 orientation: AirControlOrientation = .upright, mirrorX: Bool = false,
                 near: Double = 0.25, far: Double = 0.85) {
        guard mode != .chords || role != .single,
              let engine = MobileAirInstrument(mode:mode,keys:keys,near:near,far:far) else { return nil }
        self.engine = engine; self.role = role; self.orientation = orientation; self.mirrorX = mirrorX
    }
    /// Deadlines are derived from the original string crossings, including overlapping notes.
    public var stringDeadlines: [Int: Int64] {
        engine.ringing.compactMapValues(MobileAirCaptureFrame.nanoseconds)
    }

    public mutating func receive(_ frame: MobileAirCaptureFrame, now: Double) -> MobileAirOutput {
        let observation: MobileAirObservation?
        switch role { case .single: observation = frame.single; case .left: observation = frame.left; case .right: observation = frame.right }
        let selector = role == .left ? frame.right : frame.left
        let dual = engine.mode == .chords
        let hand = (!dual || selector?.sample != nil) ? observation?.sample?.oriented(orientation,mirrorX:mirrorX) : nil
        return engine.frame(hand:hand,fingers:dual ? selector?.fingers : nil,
                            confidence:dual ? selector?.confidence ?? 0 : 0,
                            depth:observation?.depth,at:frame.time,now:now)
    }
    public mutating func expire(now:Double) -> MobileAirOutput? { engine.expire(now:now) }
}

/// Serialize only existing authorized logical lanes. The caller still owns
/// the authenticated transport, neutral handshake, ACK pacing and watchdog.
/// No destination, sensor clock or arbitrary MIDI message is serialized.
public enum MobileAirWireLane: Sendable {
    case keys(authorized: Int)
    case helper(index: Int, authorized: Int)
    public func encode(_ output:MobileAirOutput,sequence:UInt64) throws -> Data {
        guard (1...9_007_199_254_740_991).contains(sequence) else { throw RemoteTouchError.invalidFrame }
        let fields:[String:Any]
        switch self {
        case .keys(let authorized):
            guard (1..<(1<<25)).contains(authorized), (0..<(1<<25)).contains(output.keys),
                  output.keys & authorized == output.keys,output.level == nil else { throw RemoteTouchError.invalidFrame }
            fields=["kind":"pianoKeys","version":5,"sequence":sequence,"mask":output.keys]
        case .helper(let index,let authorized):
            guard (0..<3).contains(index),(1...63).contains(authorized),authorized & (1<<index) != 0,
                  output.keys == 0,output.level.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw RemoteTouchError.invalidFrame }
            var levels=Array(repeating:0.0,count:6)
            if let level=output.level { levels[index]=level }
            fields=["kind":"pedalboard","version":6,"sequence":sequence,"mask":output.level == nil ? 0 : 1<<index,"levels":levels]
        }
        let bytes=try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys])
        _ = try RemoteTouchFrame.read(bytes)
        return bytes
    }
}
