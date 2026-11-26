import Foundation
import Testing
@testable import NoSpeakerCore

private func surfacePad(_ id:String,_ x:Int,_ y:Int,_ w:Int,_ h:Int,_ assignment:CustomSurfacePadLayout.Assignment = .note(60))->CustomSurfacePadLayout.Pad {
    .init(id:id,label:id,x:x,y:y,width:w,height:h,assignment:assignment)
}
@Test func customSurfaceLayoutMixedZonesAndGaps() throws {
    let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[
        surfacePad("drum",0,0,4000,10000,.drum(36)),
        surfacePad("tuned",5000,0,2500,10000,.degree(3)),
        surfacePad("pedal",7500,0,2500,10000,.helper(.init(.sustain)))
    ]))
    #expect(layout.pad(x:0,y:0)?.id == "drum")
    #expect(layout.pad(x:0.4,y:0.5) == nil)
    #expect(layout.pad(x:0.5,y:0.5)?.id == "tuned")
    #expect(layout.pad(x:0.75,y:0.5)?.id == "pedal")
    #expect(layout.pad(x:1,y:1)?.id == "pedal")
    #expect(layout.pad(x:.nan,y:0) == nil)
    #expect(layout.pad(x:-0.1,y:0) == nil)
    #expect(try JSONDecoder().decode(CustomSurfacePadLayout.self,from:JSONEncoder().encode(layout)) == layout)
}
@Test func customSurfaceLayoutRejectsInvalidGeometryAndAssignments() {
    let p=surfacePad("one",0,0,5000,10000)
    #expect(CustomSurfacePadLayout(surface:.magicMouse,pads:[p,surfacePad("two",4999,0,5000,10000)]) == nil)
    #expect(CustomSurfacePadLayout(surface:.magicMouse,pads:[p,surfacePad("one",5000,0,5000,10000)]) == nil)
    #expect(CustomSurfacePadLayout(surface:.tablet,pads:[surfacePad("overflow",1,0,Int.max,10000)]) == nil)
    #expect(CustomSurfacePadLayout(surface:.phone,pads:[surfacePad("bad",0,0,10000,10000,.helper(.init(.controlChange,number:101)))]) == nil)
    #expect(CustomSurfacePadLayout(surface:.phone,pads:[surfacePad("bad",0,0,10000,10000,.chord([60,60]))]) == nil)
    #expect(CustomSurfacePadLayout(surface:.touchBar,pads:[surfacePad("partial",0,0,10000,5000)]) == nil)
}
@Test func customSurfaceLayoutTouchBarAndTrackpadIndependent() throws {
    let bar=try #require(CustomSurfacePadLayout(surface:.touchBar,pads:[
        surfacePad("note",0,0,7000,10000,.degree(4)),
        surfacePad("bend",7000,0,3000,10000,.helper(.init(.pitchBend)))
    ]))
    let mouse=try #require(CustomSurfacePadLayout(surface:.magicMouse,pads:[surfacePad("drum",0,0,10000,10000,.drum(38))]))
    #expect(bar.pad(x:0.9,y:0.2)?.assignment == .helper(.init(.pitchBend)))
    #expect(mouse.pad(x:0.9,y:0.2)?.assignment == .drum(38))
    let data=try JSONEncoder().encode(bar)
    var obj=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    var pads=try #require(obj["pads"] as? [[String:Any]])
    pads[1]["x"]=6000
    obj["pads"]=pads
    let invalid=try JSONSerialization.data(withJSONObject:obj)
    #expect(throws:DecodingError.self){try JSONDecoder().decode(CustomSurfacePadLayout.self,from:invalid)}
}
