import Foundation

/// Frozen offline mapping from physical MIDI key numbers to distinct
/// tuning steps. Physical keys are never assumed to identify output
/// pitches. Unmapped keys are muted by default; explicit unlock permits
/// original MIDI pitch only, never an implicit approximation of a mapped pitch.
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
    public let allowOutsideScale: Bool
    private static let white = [0,2,4,5,7,9,11]

    public init?(tuning: MicrotonalKeyboardTuning, inputRoot: Int, layout: Layout, allowOutsideScale: Bool = false) {
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
        self.allowOutsideScale = allowOutsideScale
    }

    /// Lossless bridge from the older selected-semitone model.
    public static func legacy(_ scale: CustomScale, inputRoot: Int,
                              outputRoot: Int, referenceA4: Double = 440, allowOutsideScale: Bool = false) -> Self? {
        guard scale.isValid,
              let tuning = MicrotonalKeyboardTuning(degrees: scale.degreeCents.map(Double.init),
                  rootMIDI: outputRoot, referenceA4: referenceA4) else { return nil }
        var slots = [Int?](repeating: nil, count: 12)
        for (index,degree) in scale.intervals.enumerated() { slots[degree] = index }
        return Self(tuning: tuning, inputRoot: inputRoot, layout: .chromatic(slots), allowOutsideScale: allowOutsideScale)
    }

    /// Standard equal-tempered scale lock: physical pitch classes remain
    /// unchanged, including a non-C tonic. No microtonal approximation.
    public static func standardLock(intervals:[Int], root:Int, allowOutsideScale:Bool=false) -> Self? {
        guard (0...127).contains(root) else { return nil }
        var scale=CustomScale()
        scale.intervals=intervals
        return legacy(scale,inputRoot:root,outputRoot:root,allowOutsideScale:allowOutsideScale)
    }

    private static func whiteIndex(_ note: Int) -> Int? {
        guard let index = white.firstIndex(of: note % 12) else { return nil }
        return (note / 12) * 7 + index
    }
    private func assignedStep(_ note:Int)->Int? {
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
        return step
    }
    public func key(_ note: Int) -> Key? {
        guard (0...127).contains(note) else { return nil }
        return Key(inputNote:note,pitch:assignedStep(note).flatMap{tuning.pitch(step:$0)})
    }

    /// Keep scale membership separate from output permission. Unlock
    /// affects only unassigned keys, never invalid assigned pitches.
    public enum Output: Equatable, Sendable {
        case tuned(MicrotonalKeyboardTuning.Pitch)
        case originalMIDI(Int)
        case muted
        case unavailable
    }
    public func output(_ note:Int)->Output {
        guard (0...127).contains(note) else{return .unavailable}
        if let step=assignedStep(note) {
            guard let pitch=tuning.pitch(step:step) else{return .unavailable}
            return .tuned(pitch)
        }
        return allowOutsideScale ? .originalMIDI(note):.muted
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
        guard let pitch = key(note)?.pitch,
              let encoded = OfflineTuningMemberPitch.encode(inputNote: note, pitch: pitch,
                  bendRangeSemitones: bendRangeSemitones) else { return nil }
        return MemberPitch(inputNote: encoded.inputNote, step: encoded.step, anchor: encoded.anchor,
                           bend: encoded.bend, bendRangeSemitones: encoded.bendRangeSemitones)
    }

    /// Complete offline MPE member disposition. The original-note case
    /// must use a separately owned member channel, not a shared bypass.
    public enum MemberOutput:Equatable,Sendable {
        case tuned(MemberPitch)
        case original(inputNote:Int,anchor:Int,bend:Int,bendRangeSemitones:Int)
        case muted
        case unavailable
    }
    public func memberOutput(_ note:Int,bendRangeSemitones:Int=2)->MemberOutput {
        guard (1...96).contains(bendRangeSemitones) else{return .unavailable}
        switch output(note) {
        case .tuned:
            guard let member=memberPitch(note,bendRangeSemitones:bendRangeSemitones) else{return .unavailable}
            return .tuned(member)
        case .originalMIDI(let original):
            return .original(inputNote:note,anchor:original,bend:8192,bendRangeSemitones:bendRangeSemitones)
        case .muted:return .muted
        case .unavailable:return .unavailable
        }
    }

    public func keyboard(low: Int, high: Int) -> [Key]? {
        guard (0...127).contains(low), (low...127).contains(high) else { return nil }
        return (low...high).compactMap { key($0) }
    }
}
