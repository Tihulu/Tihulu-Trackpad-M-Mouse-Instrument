import Foundation
import Testing
@testable import NoSpeakerCore

@Test func airStrikeRequiresQuietThenOnsetAndScalesVelocity() {
    var d = AirStrikeDetector()
    let a = d.ingest(0.9, now: 1)
    let b = d.ingest(0.8, now: 1.05)
    let c = d.ingest(0.1, now: 1.1)
    let e = d.ingest(0.1, now: 1.2)
    let f = d.ingest(0.45, now: 1.25)
    let g = d.ingest(1, now: 1.3)
    #expect(a == nil && b == nil && c == nil && e == nil)
    #expect(f == 0.25)
    #expect(g == nil)
    _ = d.ingest(0.1, now: 1.4)
    _ = d.ingest(0.1, now: 1.5)
    let strong = d.ingest(1, now: 1.55)
    #expect(strong == 1)
}

@Test func airStrikeInvalidGapAndRapidReboundCannotTrigger() throws {
    let config = try #require(AirStrikeDetector.Settings(quietSeconds: 0.03, minimumInterval: 0.2))
    var d = AirStrikeDetector(settings: config)
    _ = d.ingest(0, now: 1)
    _ = d.ingest(0, now: 1.05)
    let first = d.ingest(0.8, now: 1.1)
    #expect(first != nil)
    _ = d.ingest(0, now: 1.12)
    _ = d.ingest(0, now: 1.16)
    let rebound = d.ingest(0.9, now: 1.18)
    #expect(rebound == nil)
    _ = d.ingest(0, now: 1.2)
    _ = d.ingest(0, now: 1.25)
    let stale = d.ingest(1, now: 1.7)
    let invalid = d.ingest(.nan, now: 1.8)
    let unready = d.ingest(1, now: 1.9)
    #expect(stale == nil && invalid == nil && unready == nil)
    #expect(AirStrikeDetector.Settings(threshold: 0.2, resetThreshold: 0.3) == nil)
}

private let drum = SensorDestination(.note, channel: 9, number: 38)
private func airFrame(_ sequence: Int, _ kind: String, x: Double = 0) -> Data {
    let axes = kind == "accelerationRelease" ? "" : ",\"x\":\(x),\"y\":0,\"z\":0"
    return Data(("{\"version\":3,\"sequence\":\(sequence),\"kind\":\"\(kind)\"" + axes + "}").utf8)
}
private func airPair(_ runtime: inout PhysicalPatchRuntime) throws -> UUID {
    let patch = InstrumentPatch(routes: [.init(id:"snare",source:.phone,signal:.airStrike,destination:drum,velocity:100)])
    try runtime.configure(patch, allowRemote:true)
    let token = Data(repeating: 5,count:32)
    try runtime.issueRemotePairing(secret:token,source:.phone,now:1)
    return try runtime.admitRemote(secret:token,now:1)
}
@Test func airStrikeRuntimePulseAndWatchdogRelease() throws {
    var runtime = PhysicalPatchRuntime()
    let id = try airPair(&runtime)
    let arm = runtime.receiveRemote(id,bytes:airFrame(1,"accelerationArm",x:20),now:1.1)
    #expect(arm == .accepted([]))
    let high = runtime.receiveRemote(id,bytes:airFrame(2,"acceleration",x:20),now:1.15)
    #expect(high == .accepted([]))
    _ = runtime.receiveRemote(id,bytes:airFrame(3,"acceleration"),now:1.2)
    _ = runtime.receiveRemote(id,bytes:airFrame(4,"acceleration"),now:1.3)
    let hit = runtime.receiveRemote(id,bytes:airFrame(5,"acceleration",x:20),now:1.35)
    #expect(hit == .accepted([.init(drum,value:100)]))
    let release = runtime.expire(now:1.42)
    #expect(release == [.init(drum,value:0)])
    let held = runtime.receiveRemote(id,bytes:airFrame(6,"acceleration",x:20),now:1.43)
    #expect(held == .accepted([]))
    _ = runtime.receiveRemote(id,bytes:airFrame(7,"acceleration"),now:1.5)
    _ = runtime.receiveRemote(id,bytes:airFrame(8,"acceleration"),now:1.6)
    let again = runtime.receiveRemote(id,bytes:airFrame(9,"acceleration",x:20),now:1.65)
    #expect(again == .accepted([.init(drum,value:100)]))
    let stop = runtime.receiveRemote(id,bytes:airFrame(10,"accelerationRelease"),now:1.66)
    #expect(stop == .accepted([.init(drum,value:0)]))
}
@Test func airStrikeRuntimeRejectsNonNoteRoutesAndReleasesOnRevoke() throws {
    let invalid = InstrumentPatch(routes:[.init(id:"bad",source:.phone,signal:.airStrike,destination:.init(.sustain))])
    #expect(!PhysicalPatchRuntime.supports(invalid,allowRemote:true))
    var runtime = PhysicalPatchRuntime()
    let id = try airPair(&runtime)
    _ = runtime.receiveRemote(id,bytes:airFrame(1,"accelerationArm"),now:1.1)
    _ = runtime.receiveRemote(id,bytes:airFrame(2,"acceleration"),now:1.2)
    _ = runtime.receiveRemote(id,bytes:airFrame(3,"acceleration"),now:1.3)
    _ = runtime.receiveRemote(id,bytes:airFrame(4,"acceleration",x:20),now:1.35)
    let release = runtime.revokeRemote(id)
    #expect(release == [.init(drum,value:0)])
}
