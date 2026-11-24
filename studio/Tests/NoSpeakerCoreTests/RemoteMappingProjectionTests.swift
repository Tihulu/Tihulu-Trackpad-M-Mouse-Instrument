import Foundation
import Testing
@testable import NoSpeakerCore

private func mappingFixture() -> InstrumentPatch {
    .init(name:"Private patch name",routes:[
        .init(id:"private-route",source:.phone,signal:.contact,destination:.init(.note,channel:2,number:70)),
        .init(id:"fanout-a",source:.phone,signal:.contact,destination:.init(.note,channel:2,number:70)),
        .init(id:"fanout-b",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"tablet",source:.tablet,signal:.drumPad1,destination:.init(.note,channel:9,number:38)),
        .init(id:"local",source:.trackpad,signal:.x,destination:.init(.controlChange,number:74))
    ])
}
@Test func mappingProjectionIsSourceBoundSortedAndGrouped() throws {
    let projection = try RemoteMappingProjection(patch:mappingFixture(),source:.phone)
    #expect(projection.rows == [[2,0,0,60,1],[2,0,2,70,2]])
    let page = try projection.page(0,sequence:2,detail:true)
    #expect(page.total == 2)
    let encoded = try page.encoded()
    #expect(encoded.count <= 256)
    #expect(!String(decoding:encoded,as:UTF8.self).contains("private"))
    let tablet = try RemoteMappingProjection(patch:mappingFixture(),source:.tablet)
    #expect(tablet.rows == [[9,0,9,38,1]])
    #expect(throws:RemoteTouchError.invalidFrame) { try RemoteMappingProjection(patch:mappingFixture(),source:.trackpad) }
}
@Test func mappingConsentDefaultsOffAndIsBoundToInvitation() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(mappingFixture(),allowRemote:true)
    let key = Data(repeating:83,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1,mappingDetails:true)
    let visible = try runtime.admitRemote(secret:key,now:1)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1.1)
    let hidden = try runtime.admitRemote(secret:key,now:1.1)
    let detail = try runtime.remoteMappingPage(visible,page:0,sequence:2)
    let withheld = try runtime.remoteMappingPage(hidden,page:0,sequence:2)
    #expect(detail.detail && detail.total == 2)
    #expect(!withheld.detail && withheld.total == 0 && withheld.rows.isEmpty && withheld.pages == 1)
    #expect(throws:RemoteTouchError.invalidFrame) { try runtime.remoteMappingPage(hidden,page:1,sequence:3) }
    let touch = Data(#"{"version":1,"sequence":1,"kind":"touch","x":0.5,"y":0.5}"#.utf8)
    _ = runtime.receiveRemote(visible,bytes:touch,now:1.2)
    #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingPage(visible,page:0,sequence:2) }
    _ = runtime.revokeRemote(visible)
    #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingPage(visible,page:0,sequence:2) }
    #expect(try runtime.remoteMappingPage(hidden,page:0,sequence:2).detail == false)
}
@Test func mappingProjectionPaginatesMaximumRoutesWithinWireLimit() throws {
    let routes = (0..<64).map { i in
        SensorMapping(id:"route-\(i)",source:.phone,signal:.contact,destination:.init(.note,channel:15,number:64+i))
    }
    let projection = try RemoteMappingProjection(patch:.init(routes:routes),source:.phone)
    #expect(projection.rows.count == 64)
    var collected: [[Int]] = []
    for i in 0..<8 {
        let page = try projection.page(i,sequence:9_007_199_254_740_991,detail:true)
        #expect(page.pages == 8 && page.total == 64 && page.rows.count == 8)
        #expect(try page.encoded().count <= 256)
        collected += page.rows
    }
    #expect(collected == projection.rows)
    #expect(throws:RemoteTouchError.invalidFrame) { try projection.page(8,sequence:1,detail:true) }
}
