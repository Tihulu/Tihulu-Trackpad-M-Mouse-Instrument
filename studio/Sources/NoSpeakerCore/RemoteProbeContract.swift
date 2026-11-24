import Foundation

/// Read-only diagnostic contract. It does not grant LAN access by itself,
/// configure hardware, or infer successful MIDI delivery from an ACK.
public enum RemoteProbeContract {
    public static func expected(patch: InstrumentPatch, source: SensorSource) throws -> RemoteCapabilities {
        guard source == .phone || source == .tablet,
              PhysicalPatchRuntime.supports(patch, allowRemote:true) else { throw RemoteTouchError.unavailable }
        let signals = Set(patch.routes.filter { $0.source == source }.map(\.signal))
        guard !signals.isEmpty else { throw RemoteTouchError.unavailable }
        func mask(_ values: [SensorSignal]) -> Int {
            values.enumerated().reduce(0) { $0 | (signals.contains($1.element) ? 1 << $1.offset : 0) }
        }
        return .init(touch: !signals.isDisjoint(with:[.x,.y,.contact]),
                     tilt: !signals.isDisjoint(with:[.tiltYaw,.tiltPitch,.tiltRoll]),
                     acceleration: signals.contains(.accelerationMagnitude) || signals.contains(.airStrike),
                     rotation: signals.contains(.rotationMagnitude), airDrums: signals.contains(.airStrike),
                     drums:mask(RemoteDrumPads.signals), piano:mask(RemotePiano.signals), pedals:mask(RemotePedalboard.signals))
    }

    private struct Capabilities: Decodable {
        let kind: String
        let version: Int
        let touch,tilt,acceleration,rotation,airDrums: Bool
        let drums,piano,pedals: Int
    }
    private struct Withheld: Decodable {
        let kind: String
        let version: Int
        let sequence: UInt64
        let page,pages,total: Int
        let detail: Bool
        let rows: [[Int]]
    }
    public static func acceptsCapabilities(_ bytes: Data, expected: RemoteCapabilities) -> Bool {
        guard RemoteFlatJSON.uniqueKeys(bytes) == Set(["kind","version","touch","tilt","acceleration","rotation","airDrums","drums","piano","pedals"]),
              let v = try? JSONDecoder().decode(Capabilities.self,from:bytes),
              v.kind == "capabilities", v.version == 7 else { return false }
        return RemoteCapabilities(touch:v.touch,tilt:v.tilt,acceleration:v.acceleration,rotation:v.rotation,
                                  airDrums:v.airDrums,drums:v.drums,piano:v.piano,pedals:v.pedals) == expected
    }
    public static func acceptsWithheldMapping(_ bytes: Data, sequence: UInt64) -> Bool {
        guard RemoteFlatJSON.uniqueKeys(bytes) == Set(["kind","version","sequence","page","pages","total","detail","rows"]),
              let v = try? JSONDecoder().decode(Withheld.self,from:bytes) else { return false }
        return v.kind == "mapping" && v.version == 8 && v.sequence == sequence &&
            v.page == 0 && v.pages == 1 && v.total == 0 && !v.detail && v.rows.isEmpty
    }
}
