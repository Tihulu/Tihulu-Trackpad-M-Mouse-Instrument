import Foundation

/// Bounded logical capability manifest for one admitted source. No MIDI
/// destination data or identifiers cross this interface.
public struct RemoteCapabilities: Encodable, Equatable, Sendable {
    public let kind = "capabilities"
    public let version = 7
    public let touch: Bool
    public let tilt: Bool
    public let acceleration: Bool
    public let rotation: Bool
    public let airDrums: Bool
    public let drums: Int
    public let piano: Int
    public let pedals: Int

    public init(touch: Bool, tilt: Bool, acceleration: Bool, rotation: Bool,
                airDrums: Bool, drums: Int, piano: Int, pedals: Int) {
        self.touch = touch; self.tilt = tilt; self.acceleration = acceleration
        self.rotation = rotation; self.airDrums = airDrums
        self.drums = drums; self.piano = piano; self.pedals = pedals
    }
    public func encoded() throws -> Data {
        guard (0...255).contains(drums), (0...RemotePiano.maximumMask).contains(piano),
              (0...RemotePedalboard.maximumMask).contains(pedals),
              !airDrums || acceleration else { throw RemoteTouchError.invalidFrame }
        let data = try JSONEncoder().encode(self)
        guard data.count <= RemoteTouchFrame.maximumBytes else { throw RemoteTouchError.invalidFrame }
        return data
    }
}
