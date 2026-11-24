import Foundation
import Testing
@testable import NoSpeakerCore

private func pianoFrame(_ sequence: Int, _ mask: Int, version: Int = 5) -> Data {
    Data("{\"version\":\(version),\"sequence\":\(sequence),\"kind\":\"pianoKeys\",\"mask\":\(mask)}".utf8)
}
private func pianoPair(_ runtime: inout PhysicalPatchRuntime, routes: [SensorMapping] = RemotePiano.routes()) throws -> UUID {
    try runtime.configure(.init(routes: routes), allowRemote: true)
    let token = Data(repeating: 53, count: 32)
    try runtime.issueRemotePairing(secret: token, source: .phone, now: 1)
    return try runtime.admitRemote(secret: token, now: 1)
}
private let lowC = SensorDestination(.note, number: 48)
private let middleC = SensorDestination(.note, number: 60)
private let highC = SensorDestination(.note, number: 72)
private let pedal = SensorDestination(.sustain)

@Test func remotePianoPoliphonyAndIndependentRelease() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pianoPair(&runtime)
    let mask = 1 | (1 << 12) | (1 << 24)
    let on = runtime.receiveRemote(id, bytes: pianoFrame(1,mask), now: 1.1)
    #expect(on == .accepted([.init(highC,value:100),.init(middleC,value:100),.init(lowC,value:100)]))
    let same = runtime.receiveRemote(id, bytes: pianoFrame(2,mask), now: 1.2)
    #expect(same == .accepted([]))
    let lift = runtime.receiveRemote(id, bytes: pianoFrame(3,1 << 12), now: 1.3)
    #expect(lift == .accepted([.init(lowC,value:0),.init(highC,value:0)]))
    let end = runtime.receiveRemote(id, bytes: pianoFrame(4,0), now: 1.4)
    #expect(end == .accepted([.init(middleC,value:0)]))
}

@Test func remotePianoSustainAndTimeoutRelease() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pianoPair(&runtime)
    let first = runtime.receiveRemote(id, bytes: pianoFrame(1,RemotePiano.sustainBit | 1), now: 1.1)
    #expect(first == .accepted([.init(pedal,value:127),.init(lowC,value:100)]))
    let lift = runtime.receiveRemote(id, bytes: pianoFrame(2,RemotePiano.sustainBit), now: 1.2)
    #expect(lift == .accepted([.init(lowC,value:0)]))
    let expired = runtime.expire(now: 1.6)
    #expect(expired == [.init(pedal,value:0)])
    #expect(runtime.remotePeerIDs.isEmpty)
}

@Test func remotePianoZeroMaskReleasesKeysAndSustain() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pianoPair(&runtime)
    _ = runtime.receiveRemote(id, bytes: pianoFrame(1,RemotePiano.sustainBit | 1), now: 1.1)
    let end = runtime.receiveRemote(id, bytes: pianoFrame(2,0), now: 1.2)
    #expect(end == .accepted([.init(lowC,value:0),.init(pedal,value:0)]))
    #expect(runtime.remotePeerIDs.contains(id))
}

@Test func remotePianoUnmappedBitsAndSchemaFailClosed() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try pianoPair(&runtime,routes: Array(RemotePiano.routes().prefix(1)))
    _ = runtime.receiveRemote(id,bytes:pianoFrame(1,1),now:1.1)
    let rejected = runtime.receiveRemote(id,bytes:pianoFrame(2,3),now:1.2)
    #expect(rejected == .close([.init(lowC,value:0)]))
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pianoFrame(1,1<<26)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pianoFrame(1,1,version:4)) }
    #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(pianoFrame(1,-1)) }
    var route = RemotePiano.routes()[0]
    route.destination = .init(.sustain)
    #expect(!InstrumentPatch(routes:[route]).isValid)
    #expect(InstrumentPatch(routes: RemotePiano.routes()).isValid)
}
