import Foundation

/// Project existing native envelope metadata before the legacy preview's
/// filtering/clamping. Invalid envelopes remain explicit invalid frames.
public enum NativeHelperRelativeEnvelope {
    public typealias Clutch = NativeHelperRelativeClutch
    public struct Record: Sendable {
        public let state: Int
        public let isDown: Bool
        public let contact: Clutch.Contact
        public init(state: Int, isDown: Bool, contact: Clutch.Contact) {
            self.state = state; self.isDown = isDown; self.contact = contact
        }
    }

    /// Conservative initial release policy: only a real zero-record native
    /// envelope proves neutral. A lift-state-only frame is not yet approved
    /// as a neutral boundary on physical devices. Mixed frames still require
    /// exact record/state parity; no unknown state can disappear by filtering.
    public static func project(surface: Clutch.Surface, registration: UUID?, registrationCurrent: Bool,
                               acquisitionNS: Int64?, validEnvelope: Bool, rawCount: Int?,
                               rawStates: [Int], records: [Record], maximumRecords: Int) -> Clutch.SourceFrame {
        let down = records.filter(\.isDown).map(\.contact)
        let receipt = acquisitionNS.map { Double($0) / 1_000_000_000 } ?? .nan
        let count = rawCount ?? -1
        let valid = registration != nil && registrationCurrent && (acquisitionNS.map { $0 >= 0 } ?? false) &&
            validEnvelope && maximumRecords > 0 && count >= 0 && count <= maximumRecords &&
            count == rawStates.count && count == records.count &&
            rawStates == records.map(\.state) && records.allSatisfy {
                (3...5).contains($0.state) && $0.isDown == ($0.state != 5) &&
                $0.contact.surface == surface && $0.contact.id >= 0 &&
                [$0.contact.x, $0.contact.y, $0.contact.contactSize].allSatisfy { $0.isFinite && (0...1).contains($0) }
            } && Set(records.map { $0.contact.id }).count == records.count && (count == 0 || !down.isEmpty)
        return .init(surface: surface, rawDownCount: down.count, sourceConsistent: valid,
                     contacts: down, receipt: receipt, nativeRegistration: registration, acquisitionNS: acquisitionNS)
    }
}
