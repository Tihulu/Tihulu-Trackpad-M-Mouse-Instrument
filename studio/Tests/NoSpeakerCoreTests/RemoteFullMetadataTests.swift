import Foundation
import Testing
@testable import NoSpeakerCore

/// Exercise actual host projection, authorization and dispatch at the maximum
/// supported signal count. The browser has a separate full-page regression.
@Test func fullRemoteMetadataSnapshotUsesBoundedHostResponses() throws {
    let signals = RemoteMappingProjection.signals
    #expect(signals.count == 49)
    let routes = signals.enumerated().map { i,signal -> SensorMapping in
        let destination: SensorDestination
        switch i {
        case 8...41: destination = .init(.note, channel: 15, number: 60)
        case 42,46: destination = .init(.sustain, channel: 15)
        case 47,48: destination = .init(.controlChange, channel: 15, number: 80+i-47)
        default: destination = .init(.controlChange, channel: 15, number: 74)
        }
        return .init(id:"full-\(i)",source:.phone,signal:signal,destination:destination,
                     threshold:i == 8 ? 0.45 : 0.55,hysteresis:i == 8 ? 0.25 : 0.08)
    } + (0..<15).map { i in
        SensorMapping(id:"extra-\(i)",source:.phone,signal:.x,
                      destination:.init(.note,channel:15,number:100+i))
    }
    let widgets = signals.map { PerformanceWidget(source:.phone,signal:$0,label:String(repeating:"A",count:64)) }
    let patch = InstrumentPatch(routes:routes,performanceLayout:.init(widgets:widgets))
    #expect(PhysicalPatchRuntime.supports(patch,allowRemote:true))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true)
    var bridge = RemoteHostBridge()
    let connection = UUID(), key = Data(repeating:91,count:32)
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:key,source:.phone,now:1,runtime:&runtime,mappingDetails:true,mappingLabels:true)
    #expect(bridge.process([.invitation(connection,key,1)],now:1,runtime:&runtime).actions == [.acknowledge(connection,true)])
    let caps = Data(#"{"version":7,"sequence":1,"kind":"capabilities"}"#.utf8)
    _ = bridge.process([.frame(connection,caps,1.1)],now:1.1,runtime:&runtime)
    var sequence: UInt64 = 9_007_199_254_740_900
    var now = 1.2
    var rows: [[Int]] = []
    for page in 0..<8 {
        let bytes = Data("{\"version\":8,\"sequence\":\(sequence),\"kind\":\"mapping\",\"page\":\(page)}".utf8)
        let response = bridge.process([.frame(connection,bytes,now)],now:now,runtime:&runtime)
        #expect(response.commands.isEmpty)
        if case .mapping(let id,let p) = response.actions.first {
            #expect(id == connection && p.sequence == sequence && p.total == 64 && p.page == page && p.pages == 8)
            #expect(try p.encoded().count <= 256)
            rows += p.rows
        } else { Issue.record("Missing destination page") }
        sequence += 1; now += 0.11
    }
    #expect(rows.count == 64 && Set(rows.map { $0[0] }).count == 49)
    for page in 0..<49 {
        let bytes = Data("{\"version\":8,\"sequence\":\(sequence),\"kind\":\"mappingLabels\",\"page\":\(page)}".utf8)
        let response = bridge.process([.frame(connection,bytes,now)],now:now,runtime:&runtime)
        #expect(response.commands.isEmpty)
        if case .mappingLabels(let id,let p) = response.actions.first {
            #expect(id == connection && p.sequence == sequence && p.total == 49 && p.page == page && p.pages == 49)
            #expect(p.rows == [.init(signal:page,text:String(repeating:"A",count:64))])
            #expect(try p.encoded().count <= 256)
        } else { Issue.record("Missing label page") }
        sequence += 1; now += 0.11
    }
    let touch = Data("{\"version\":1,\"sequence\":\(sequence),\"kind\":\"touch\",\"x\":0.2,\"y\":0.3}".utf8)
    #expect(bridge.process([.frame(connection,touch,now)],now:now,runtime:&runtime).actions == [.acknowledge(connection,true)])
    #expect(!bridge.revoke(connection,runtime:&runtime).commands.isEmpty)
    #expect(runtime.remotePeerIDs.isEmpty)
}
