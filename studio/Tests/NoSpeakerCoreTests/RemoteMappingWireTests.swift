import Foundation
import Testing
@testable import NoSpeakerCore

private func metadataRequest(_ sequence: Int,_ page: Int = 0) -> Data {
    Data("{\"version\":8,\"sequence\":\(sequence),\"kind\":\"mapping\",\"page\":\(page)}".utf8)
}
private func metadataCaps(_ sequence: Int = 1) -> Data {
    Data("{\"version\":7,\"sequence\":\(sequence),\"kind\":\"capabilities\"}".utf8)
}
private func metadataRuntime() throws -> PhysicalPatchRuntime {
    var runtime = PhysicalPatchRuntime()
    let routes = (0..<9).map { i in
        SensorMapping(id:"meta-\(i)",source:.phone,signal:.contact,destination:.init(.note,number:60+i))
    }
    try runtime.configure(.init(routes:routes),allowRemote:true)
    return runtime
}
private func metadataPair(_ runtime: inout PhysicalPatchRuntime, details: Bool = true) throws -> UUID {
    let key = Data(repeating:84,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1,mappingDetails:details)
    return try runtime.admitRemote(secret:key,now:1)
}
@Test func mappingWireRequiresCanonicalPageAndExactFields() throws {
    #expect(try RemoteTouchFrame.read(metadataRequest(1,7)).page == 7)
    for bad in [
        #"{"version":8,"sequence":1,"kind":"mapping","page":0.0}"#,
        #"{"version":8,"sequence":1,"kind":"mapping","page":-0}"#,
        #"{"version":8,"sequence":1,"kind":"mapping","page":0,"\u0070age":0}"#,
        #"{"version":8,"sequence":1,"kind":"mapping","page":8}"#,
        #"{"version":8,"sequence":1,"kind":"mapping","page":0,"detail":true}"#,
        #"{"version":8,"sequence":1,"kind":"mapping","page":0,"rows":[]}"#
    ] {
        #expect(throws:RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(Data(bad.utf8)) }
    }
}
@Test func mappingWirePhaseRejectsPrematureSkippedRepeatedAndFastQueries() throws {
    for scenario in 0..<5 {
        var runtime = try metadataRuntime()
        let id = try metadataPair(&runtime)
        if scenario == 0 {
            #expect(runtime.receiveRemote(id,bytes:metadataRequest(1),now:1.1) == .close([]))
        } else {
            #expect(runtime.receiveRemote(id,bytes:metadataCaps(),now:1.1) == .accepted([]))
            if scenario == 1 {
                #expect(runtime.receiveRemote(id,bytes:metadataRequest(2,1),now:1.2) == .close([]))
            } else {
                #expect(runtime.receiveRemote(id,bytes:metadataRequest(2),now:1.2) == .accepted([]))
                if scenario == 2 {
                    #expect(runtime.receiveRemote(id,bytes:metadataRequest(3),now:1.3) == .close([]))
                } else if scenario == 3 {
                    #expect(runtime.receiveRemote(id,bytes:metadataRequest(3,1),now:1.21) == .close([]))
                } else {
                    let heartbeat = Data(#"{"version":1,"sequence":3,"kind":"heartbeat"}"#.utf8)
                    #expect(runtime.receiveRemote(id,bytes:heartbeat,now:1.3) == .close([]))
                }
            }
        }
        #expect(runtime.remotePeerIDs.isEmpty)
    }
}
@Test func mappingWireBridgeReturnsBoundedPagesThenAllowsLegacyPerformance() throws {
    var runtime = try metadataRuntime()
    var bridge = RemoteHostBridge()
    let key = Data(repeating:84,count:32), connection = UUID()
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:key,source:.phone,now:1,runtime:&runtime,mappingDetails:true)
    _ = bridge.process([.invitation(connection,key,1)],now:1,runtime:&runtime)
    _ = bridge.process([.frame(connection,metadataCaps(),1.1)],now:1.1,runtime:&runtime)
    for i in 0..<2 {
        let now = 1.2+Double(i)*0.1
        let response = bridge.process([.frame(connection,metadataRequest(i+2,i),now)],now:now,runtime:&runtime)
        #expect(response.commands.isEmpty)
        #expect(response.actions.count == 1)
        if case .mapping(let id,let page) = response.actions.first {
            #expect(id == connection)
            #expect(page.sequence == UInt64(i+2) && page.page == i && page.pages == 2 && page.total == 9)
            #expect(page.rows.count == (i == 0 ? 8 : 1))
            #expect(try page.encoded().count <= 256)
        } else { Issue.record("Missing mapping response") }
    }
    let touch = Data(#"{"version":1,"sequence":4,"kind":"touch","x":0.5,"y":0.5}"#.utf8)
    let play = bridge.process([.frame(connection,touch,1.4)],now:1.4,runtime:&runtime)
    #expect(play.actions == [.acknowledge(connection,true)])
    #expect(play.commands.count == 9)
    let deny = bridge.process([.frame(connection,metadataRequest(5),1.5)],now:1.5,runtime:&runtime)
    #expect(deny.actions == [.acknowledge(connection,false)])
    #expect(deny.commands.count == 9)
}
@Test func mappingWireWithheldSnapshotCompletesWithoutCountLeak() throws {
    var runtime = try metadataRuntime()
    let id = try metadataPair(&runtime,details:false)
    #expect(runtime.receiveRemote(id,bytes:metadataCaps(),now:1.1) == .accepted([]))
    #expect(runtime.receiveRemote(id,bytes:metadataRequest(2),now:1.2) == .accepted([]))
    let page = try runtime.remoteMappingPage(id,page:0,sequence:2)
    #expect(!page.detail && page.total == 0 && page.rows.isEmpty)
    #expect(runtime.receiveRemote(id,bytes:metadataRequest(3),now:1.3) == .close([]))
}
