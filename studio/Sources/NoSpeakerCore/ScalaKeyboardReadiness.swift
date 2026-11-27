import Foundation

/// Offline receiver arithmetic, not port discovery, receiver feedback,
/// channel admission, hardware measurements, or a playback authorization.
public struct ScalaKeyboardReadiness: Equatable, Sendable {
    public struct Projection: Equatable, Sendable {
        public let member: OfflineTuningMemberPitch
        public let targetHz: Double
        public let encodedHz: Double
        /// Signed quantization error, not a measured receiver error.
        public let errorCents: Double
        public let downwardHeadroomCents: Double
        public let upwardHeadroomCents: Double
    }
    public enum Disposition: Equatable, Sendable {
        case projected(Projection)
        case unmapped, outsideRange, unavailablePitch, unavailableMember
    }
    public struct Entry: Equatable, Sendable {
        public let inputNote: Int
        public let disposition: Disposition
    }
    public struct CoincidentAnchor: Equatable, Sendable {
        public let anchor: Int
        public let inputNotes: [Int]
        public let distinctStepCount: Int
    }
    public let bendRangeSemitones: Int
    public let entries: [Entry]
    public let coincidentAnchors: [CoincidentAnchor]
    public let projectedCount: Int
    public let unmappedCount: Int
    public let outsideRangeCount: Int
    public let unavailablePitchCount: Int
    public let unavailableMemberCount: Int
    public let maximumAbsoluteErrorCents: Double?
    public let reference: Entry

    public init?(preview: ScalaKeyboardPreview, bendRangeSemitones: Int = 2) {
        guard (1...96).contains(bendRangeSemitones) else { return nil }
        self.bendRangeSemitones = bendRangeSemitones
        var rows: [Entry] = []
        var groups: [Int: [OfflineTuningMemberPitch]] = [:]
        var projected = 0, unmapped = 0, outside = 0, unavailablePitch = 0, unavailableMember = 0
        var maxError: Double?
        for note in 0...127 {
            let disposition: Disposition
            switch preview.output(note) {
            case .unmapped: disposition = .unmapped; unmapped += 1
            case .outsideRange: disposition = .outsideRange; outside += 1
            case .unavailable: disposition = .unavailablePitch; unavailablePitch += 1
            case .tuned(let pitch):
                if case .tuned(let member) = preview.memberOutput(note, bendRangeSemitones: bendRangeSemitones),
                   let neutral = OfflineTuningExpression.zone(base: member, masterBend: 8192,
                                                               masterRangeSemitones: bendRangeSemitones) {
                    let base = neutral.predictedPitchFromAnchorCents
                    let encodedHz = 440 * pow(2, (Double(member.anchor - 69) + base / 100) / 12)
                    let error = 1200 * log2(encodedHz / pitch.frequency)
                    let limit = Double(bendRangeSemitones) * 100
                    disposition = .projected(.init(member: member, targetHz: pitch.frequency,
                        encodedHz: encodedHz, errorCents: error,
                        downwardHeadroomCents: limit + base, upwardHeadroomCents: limit - base))
                    groups[member.anchor, default: []].append(member)
                    maxError = max(maxError ?? 0, abs(error))
                    projected += 1
                } else { disposition = .unavailableMember; unavailableMember += 1 }
            }
            rows.append(.init(inputNote: note, disposition: disposition))
        }
        entries = rows
        coincidentAnchors = groups.keys.sorted().compactMap { anchor in
            guard let members = groups[anchor], members.count > 1 else { return nil }
            return .init(anchor: anchor, inputNotes: members.map(\.inputNote),
                         distinctStepCount: Set(members.map(\.step)).count)
        }
        projectedCount = projected
        unmappedCount = unmapped
        outsideRangeCount = outside
        unavailablePitchCount = unavailablePitch
        unavailableMemberCount = unavailableMember
        maximumAbsoluteErrorCents = maxError
        reference = rows[preview.mapping.reference]
    }
}
