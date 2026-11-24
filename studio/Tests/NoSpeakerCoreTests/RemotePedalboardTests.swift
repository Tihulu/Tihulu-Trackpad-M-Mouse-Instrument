import Foundation
import Testing
@testable import NoSpeakerCore

private func pedals(_ sequence: Int, _ mask: Int, _ levels: [Double], version: Int = 6) -> Data {
    Data("{\"version\":\(version),\"sequence\":\(sequence),\"kind\":\"pedalboard\",\"mask\":\(mask),\"levels\":[\(levels.map { $0 == 0 ? "0" : $0 == 1 ? "1" : String($0) }.joined(separator: ","))]}".utf8)
}
private func pedalPair(_ runtime: inout PhysicalPatchRuntime, routes: [SensorMapping] = RemotePedalboard.routes()) throws -> UUID {
    try runtime.configure(.init(routes: routes), allowRemote: true)
    let key = Data(repeating: 61, count: 32)
    try runtime.issueRemotePairing(secret: key, source: .phone, now: 1)
    return try runtime.admitRemote(secret: key, now: 1)
}
private let expression = SensorDestination(.controlChange,number:11)
private let volume = SensorDestination(.controlChange,number:7)
private let effect = SensorDestination(.controlChange,number:80)
private let sustain = SensorDestination(.sustain)

@Test func pedalboardContinuousAndBinaryOwnership() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pedalPair(&runtime)
    let first = runtime.receiveRemote(id,bytes:pedals(1,19,[0.5,0.25,0,0,1,0]),now:1.1)
    #expect(first == .accepted([.init(expression,value:64),.init(volume,value:32),.init(effect,value:127)]))
    let update = runtime.receiveRemote(id,bytes:pedals(2,17,[0.75,0,0,0,1,0]),now:1.2)
    #expect(update == .accepted([.init(expression,value:95),.init(volume,value:127)]))
    let release = runtime.receiveRemote(id,bytes:pedals(3,0,[0,0,0,0,0,0]),now:1.3)
    #expect(release == .accepted([.init(expression,value:127),.init(effect,value:0)]))
}

@Test func pedalboardWatchdogReleasesEvenWithOtherTraffic() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pedalPair(&runtime,routes:RemotePedalboard.routes() + RemotePiano.routes())
    _ = runtime.receiveRemote(id,bytes:pedals(1,8,[0,0,0,1,0,0]),now:1.1)
    let piano = Data("{\"version\":5,\"sequence\":2,\"kind\":\"pianoKeys\",\"mask\":1}".utf8)
    _ = runtime.receiveRemote(id,bytes:piano,now:1.4)
    let release = runtime.expire(now:1.5)
    #expect(release.contains(.init(sustain,value:0)))
    #expect(release.contains(.init(.init(.note,number:48),value:0)))
    #expect(runtime.remotePeerIDs.isEmpty)
}

@Test func pedalboardRejectsUnmappedAndMalformedSnapshots() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pedalPair(&runtime,routes:Array(RemotePedalboard.routes().prefix(1)))
    _ = runtime.receiveRemote(id,bytes:pedals(1,1,[0.5,0,0,0,0,0]),now:1.1)
    let bad = runtime.receiveRemote(id,bytes:pedals(2,3,[0.5,0.5,0,0,0,0]),now:1.2)
    #expect(bad == .close([.init(expression,value:127)]))
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pedals(1,64,[0,0,0,0,0,0])) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pedals(1,0,[1,0,0,0,0,0])) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pedals(1,16,[0,0,0,0,0.5,0])) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pedals(1,1,[0.5])) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pedals(1,1,[0.5,0,0,0,0,0],version:5)) }
}

@Test func pedalboardRoutePolicyAndSavedPreset() throws {
    let patch = InstrumentPatch(routes:RemotePedalboard.routes())
    #expect(patch.isValid)
    let restored = try InstrumentPatch.read(patch.archive())
    #expect(restored == patch)
    var route = patch.routes[4]
    route.destination = .init(.controlChange,number:7)
    #expect(!InstrumentPatch(routes:[route]).isValid)
    route.destination = effect
    route.response = .init(smoothingMS:20)
    #expect(!InstrumentPatch(routes:[route]).isValid)
    route.response = nil
    route.calibration.inverted = true
    #expect(!InstrumentPatch(routes:[route]).isValid)
}
