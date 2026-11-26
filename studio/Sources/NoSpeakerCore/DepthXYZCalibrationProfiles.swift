import Foundation

/// Device-local camera calibration and enabled helper axes. Receiver MIDI
/// destinations and credentials are never stored in a calibration profile.
public struct DepthXYZCalibrationProfiles: Codable, Equatable, Sendable {
    public struct Profile: Codable, Equatable, Identifiable, Sendable {
        public let name: String
        public let volume: DepthXYZVolume
        public let axisMask: Int
        public let pitchAxis: DepthXYZPitchAxis?
        public var id: String { name.lowercased() }
    }

    public static let capacity = 32
    public private(set) var profiles: [Profile] = []

    public init() {}

    public enum Failure: Error, Equatable { case invalidName, invalidSettings, duplicate, full }

    /// Saving never overwrites an existing calibration.
    public mutating func save(name: String, volume: DepthXYZVolume, axisMask: Int, pitchAxis: DepthXYZPitchAxis? = nil) throws {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 64,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.invalidName
        }
        guard volume.isValid, (1...7).contains(axisMask) else { throw Failure.invalidSettings }
        guard !profiles.contains(where: { $0.id == key.lowercased() }) else { throw Failure.duplicate }
        guard profiles.count < Self.capacity else { throw Failure.full }
        profiles.append(Profile(name: key, volume: volume, axisMask: axisMask, pitchAxis: pitchAxis))
    }

    public mutating func remove(id: String) { profiles.removeAll { $0.id == id } }

    private enum CodingKeys: String, CodingKey { case profiles }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .profiles)
        while !list.isAtEnd {
            guard profiles.count < Self.capacity else { throw Failure.full }
            let profile = try list.decode(Profile.self)
            try save(name: profile.name, volume: profile.volume, axisMask: profile.axisMask, pitchAxis: profile.pitchAxis)
        }
    }
}
