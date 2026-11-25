import Foundation
import Testing
@testable import NoSpeakerCore

@Test func partyJamPresetFitsBoundedRouterAndReservesAllPlayers() throws {
    let patch = try #require(PartyJamPreset.patch())
    #expect(patch.routes.count <= SensorRouter.maxMappings)
    #expect(Set(patch.routes.map(\.source)) == [.phone,.tablet,.gamepad1,.gamepad2,.trackpad,.magicMouse,.lid,.touchBar,.camera])
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true)
    #expect(runtime.reservedGamepadSessions == 2)
    let secret = Data(repeating:23,count:32)
    for (i,source) in [SensorSource.phone,.tablet,.phone,.tablet].enumerated() {
        let now = 1+Double(i)*0.01
        try runtime.issueRemotePairing(secret:secret,source:source,now:now)
        _ = try runtime.admitRemote(secret:secret,now:now)
    }
    #expect(runtime.remotePeerIDs.count == 4)
    #expect(runtime.reservedRemoteSessions == 6)
    try runtime.issueRemotePairing(secret:secret,source:.phone,now:1.1)
    #expect(throws:RemoteTouchError.capacity) { try runtime.admitRemote(secret:secret,now:1.1) }
}
@Test func partyJamPianoAndGamepadPedalShareOwnershipWithoutGainMessages() throws {
    let patch = try #require(PartyJamPreset.patch())
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true)
    let secret = Data(repeating:23,count:32)
    try runtime.issueRemotePairing(secret:secret,source:.tablet,now:1)
    let tablet = try runtime.admitRemote(secret:secret,now:1)
    let idle = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    let pedal = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,1],sticks:[0,0,0,0]))
    let target = SensorDestination(.sustain,channel:1)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1.01)
    let on = runtime.receiveGamepad(source:.gamepad2,frame:pedal,now:1.02)
    #expect(on == [.init(target,value:127)])
    let bytes = Data(#"{"version":5,"sequence":1,"kind":"pianoKeys","mask":33554432}"#.utf8)
    let shared = runtime.receiveRemote(tablet,bytes:bytes,now:1.03)
    #expect(shared == .accepted([]))
    let controllerOff = runtime.releaseGamepad(.gamepad2)
    #expect(controllerOff.isEmpty)
    let tabletOff = runtime.revokeRemote(tablet)
    #expect(tabletOff == [.init(target,value:0)])
}
