import Foundation
import Testing
@testable import NoSpeakerCore

private func labelFixture() -> InstrumentPatch {
    .init(name:"Do not disclose this patch",routes:[
        .init(id:"a",source:.phone,signal:.x,destination:.init(.controlChange,number:74)),
        .init(id:"b",source:.phone,signal:.y,destination:.init(.controlChange,number:75)),
        .init(id:"c",source:.phone,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"d",source:.tablet,signal:.x,destination:.init(.controlChange,number:11))
    ],performanceLayout:.init(widgets:[
        .init(source:.phone,signal:.x,kind:.xy,label:"Gitar · Wah"),
        .init(source:.phone,signal:.contact,label:"   "),
        .init(source:.tablet,signal:.x,label:"Tablet only"),
        .init(source:.phone,signal:.tiltPitch,label:"Unmapped")
    ]))
}
@Test func mappingLabelsOnlyMappedSafeSourceWidgets() throws {
    let p = try RemoteMappingProjection(patch:labelFixture(),source:.phone)
    #expect(p.labels == [.init(signal:0,text:"Gitar · Wah")])
    let t = try RemoteMappingProjection(patch:labelFixture(),source:.tablet)
    #expect(t.labels == [.init(signal:0,text:"Tablet only")])
    let label = try p.labelPage(0,sequence:9_007_199_254_740_991,allowed:true)
    let data = try label.encoded()
    #expect(data.count <= 256)
    let obj = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    let rows = try #require(obj["rows"] as? [[Any]])
    #expect(rows.count == 1)
    #expect(rows[0][0] as? Int == 0)
    #expect(rows[0][1] as? String == "R2l0YXIgwrcgV2Fo")
}
@Test func mappingLabelLexicalSafetyAndBoundedPage() throws {
    for value in [""," ","\u{00a0}","\u{200b}","a\u{202e}b","a\nb",String(repeating:"é",count:33)] {
        #expect(!RemoteMappingLabel.permits(value))
    }
    for value in ["Türkçe","日本語","<b>literal</b>","e\u{301}",String(repeating:"é",count:32)] {
        #expect(RemoteMappingLabel.permits(value))
    }
    let long = RemoteMappingLabelPage(sequence:9_007_199_254_740_991,page:48,pages:49,total:49,
                                      rows:[.init(signal:48,text:String(repeating:"é",count:32))])
    #expect(try long.encoded().count <= 256)
}
@Test func mappingLabelConsentRequiresDetailsAndCompletedMapping() throws {
    let key = Data(repeating:84,count:32)
    let caps = Data(#"{"version":7,"sequence":1,"kind":"capabilities"}"#.utf8)
    let query = Data(#"{"version":8,"sequence":2,"kind":"mapping","page":0}"#.utf8)
    for (details,labels) in [(false,true),(true,false),(true,true)] {
        var runtime = PhysicalPatchRuntime()
        try runtime.configure(labelFixture(),allowRemote:true)
        try runtime.issueRemotePairing(secret:key,source:.phone,now:1,mappingDetails:details,mappingLabels:labels)
        let id = try runtime.admitRemote(secret:key,now:1)
        #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingLabelPage(id,page:0,sequence:3) }
        #expect(runtime.receiveRemote(id,bytes:caps,now:1.1) == .accepted([]))
        #expect(runtime.receiveRemote(id,bytes:query,now:1.2) == .accepted([]))
        if details {
            let page = try runtime.remoteMappingLabelPage(id,page:0,sequence:3)
            #expect(page.total == (labels ? 1 : 0))
            #expect(page.rows.count == page.total)
        } else {
            #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingLabelPage(id,page:0,sequence:3) }
        }
        _ = runtime.revokeRemote(id)
        #expect(throws:RemoteTouchError.unavailable) { try runtime.remoteMappingLabelPage(id,page:0,sequence:3) }
    }
}
