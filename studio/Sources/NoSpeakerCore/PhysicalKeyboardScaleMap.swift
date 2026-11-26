import Foundation

/// Frozen offline mapping from physical MIDI key numbers to distinct
/// tuning steps. Physical keys are never assumed to identify output
/// pitches. Unmapped keys are muted, not snapped or approximated.
/// Does not open CoreMIDI or authorize live playback.
public struct PhysicalKeyboardScaleMap: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// Twelve relative chromatic positions; nil is outside the scale.
        /// Entries select degrees explicitly, including quarter tones.
        case chromatic([Int?])
        /// Consecutive physical semitones advance one scale degree.
        case allKeys
        /// Only physical white keys advance a degree; black keys are muted.
        case whiteKeys
    }
    public struct Key: Equatable, Sendable {
        public let inputNote: Int
        public let pitch: MicrotonalKeyboardTuning.Pitch?
        public var isMapped: Bool { pitch != nil }
    }
    public let tuning: MicrotonalKeyboardTuning
    public let inputRoot: Int
    public let layout: Layout
    private static let white = [0,2,4,5,7,9,11]

    public init?(tuning: MicrotonalKeyboardTuning, inputRoot: Int, layout: Layout) {
        guard (0...127).contains(inputRoot) else { return nil }
        switch layout {
        case .chromatic(let slots):
            guard slots.count == 12, slots[0] == 0 else { return nil }
            let degrees = slots.compactMap { $0 }
            guard degrees.allSatisfy({ tuning.degrees.indices.contains($0) }),
                  zip(degrees,degrees.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return nil }
        case .whiteKeys:
            guard Self.white.contains(inputRoot % 12) else { return nil }
        case .allKeys: break
        }
        self.tuning = tuning
        self.inputRoot = inputRoot
        self.layout = layout
    }

    /// Lossless bridge from the older selected-semitone model.
    public static func legacy(_ scale: CustomScale, inputRoot: Int,
                              outputRoot: Int, referenceA4: Double = 440) -> Self? {
        guard scale.isValid,
              let tuning = MicrotonalKeyboardTuning(degrees: scale.degreeCents.map(Double.init),
                  rootMIDI: outputRoot, referenceA4: referenceA4) else { return nil }
        var slots = [Int?](repeating: nil, count: 12)
        for (index,degree) in scale.intervals.enumerated() { slots[degree] = index }
        return Self(tuning: tuning, inputRoot: inputRoot, layout: .chromatic(slots))
    }

    /// Standard equal-tempered scale lock: physical pitch classes remain
    /// unchanged, including a non-C tonic. No microtonal approximation.
    public static func standardLock(intervals:[Int], root:Int) -> Self? {
        guard (0...127).contains(root) else { return nil }
        var scale=CustomScale()
        scale.intervals=intervals
        return legacy(scale,inputRoot:root,outputRoot:root)
    }

    private static func whiteIndex(_ note: Int) -> Int? {
        guard let index = white.firstIndex(of: note % 12) else { return nil }
        return (note / 12) * 7 + index
    }
    public func key(_ note: Int) -> Key? {
        guard (0...127).contains(note) else { return nil }
        let step: Int?
        switch layout {
        case .allKeys: step = note - inputRoot
        case .whiteKeys:
            if let index = Self.whiteIndex(note), let root = Self.whiteIndex(inputRoot) {
                step = index - root
            } else { step = nil }
        case .chromatic(let slots):
            let delta = note - inputRoot
            let slot = ((delta % 12) + 12) % 12
            step = slots[slot].map { ((delta - slot) / 12) * tuning.degrees.count + $0 }
        }
        return Key(inputNote: note, pitch: step.flatMap { tuning.pitch(step: $0) })
    }

    public struct MemberPitch: Equatable, Sendable {
        public let inputNote: Int
        public let step: Int
        public let anchor: Int
        public let bend: Int
        public let bendRangeSemitones: Int
    }
    /// Offline encoding for a receiver explicitly configured to the same
    /// bend range and A4=440. A4 calibration is included in the bend.
    /// Input note/step identity survives coincident anchors. Never send
    /// this as a shared-channel bend or treat it as a voice allocation.
    public func memberPitch(_ note: Int, bendRangeSemitones: Int = 2) -> MemberPitch? {
        guard (1...96).contains(bendRangeSemitones),
              let pitch = key(note)?.pitch else { return nil }
        let nominal = 69 + 12 * log2(pitch.frequency / 440)
        guard nominal.isFinite else { return nil }
        let anchor = min(127,max(0,Int(nominal.rounded())))
        let fraction = (nominal - Double(anchor)) / Double(bendRangeSemitones)
        guard (-1...1).contains(fraction) else { return nil }
        let delta = Int((fraction * (fraction >= 0 ? 8191 : 8192)).rounded())
        return MemberPitch(inputNote:note,step:pitch.step,anchor:anchor,bend:8192+delta,
                           bendRangeSemitones:bendRangeSemitones)
    }

    public func keyboard(low: Int, high: Int) -> [Key]? {
        guard (0...127).contains(low), (low...127).contains(high) else { return nil }
        return (low...high).compactMap { key($0) }
    }
}
