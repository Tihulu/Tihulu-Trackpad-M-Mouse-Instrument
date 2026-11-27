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

@Test func customSurfaceLayoutGridAndValidatedEdits() throws {
    let layout=try #require(CustomSurfacePadLayout.grid(surface:.trackpad,columns:3,rows:2))
    #expect(layout.pads.count==6)
    #expect(layout.pad(x:1,y:1)?.assignment == .note(65))
    #expect(layout.pad(x:0.3333,y:0.1)?.id == "pad-2")
    let first=layout.pads[0]
    let invalid=surfacePad(first.id,0,0,10000,10000)
    #expect(layout.replacing(invalid)==nil)
    let smaller=surfacePad(first.id,0,0,1000,1000,.drum(36))
    let updated=try #require(layout.replacing(smaller))
    #expect(updated.pad(x:0.2,y:0.1)==nil)
    #expect(layout.pads[0]==first)
    let removed=try #require(updated.removing(id:first.id))
    #expect(removed.pads.count==5)
    #expect(removed.adding(smaller)?.pads.count==6)
    #expect(CustomSurfacePadLayout.grid(surface:.touchBar,columns:4,rows:2)==nil)
    #expect(CustomSurfacePadLayout.grid(surface:.phone,columns:16,rows:16)==nil)
    #expect(CustomSurfacePadLayout.grid(surface:.phone,columns:2,rows:2,firstNote:127)==nil)
}
@Test func customSurfaceLayoutRejectsChannelModeAndSwitchAxes() {
    for cc in 120...127 {
        #expect(!CustomSurfacePadLayout.Assignment.helper(.init(.controlChange,number:cc)).isValid)
    }
    #expect(!CustomSurfacePadLayout.Assignment.xy(.init(.controlChange,number:64),.init(.pitchBend)).isValid)
    #expect(CustomSurfacePadLayout.Assignment.helper(.init(.sustain)).isValid)
}

@Test func customPadGeometryEditPreservesExactChordAndHelperAssignments() throws {
    let assignments:[CustomSurfacePadLayout.Assignment]=[
        .chord([48,55,60]),.degree(-8),.helper(.init(.controlChange,channel:9,number:71)),
        .xy(.init(.controlChange,channel:3,number:10),.init(.pitchBend,channel:5))]
    for assignment in assignments {
        let pad=surfacePad("one",0,0,10000,10000,assignment)
        let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[pad]))
        let edit=pad.editingGeometry(label:"Renamed",x:100,y:200,width:3000,height:4000)
        let updated=try #require(layout.replacing(edit))
        #expect(updated.pads[0].assignment==assignment)
        #expect(updated.pads[0].label=="Renamed")
    }
}

@Test func customSurfaceGapInsertionPreservesExistingPadsAndTouchBarGeometry() throws {
    let left=surfacePad("left",0,0,3333,10000,.chord([60,64,67]))
    let right=surfacePad("right",6666,0,3334,10000,.helper(.init(.pitchBend)))
    let bar=try #require(CustomSurfacePadLayout(surface:.touchBar,pads:[left,right]))
    let added=try #require(bar.addingInGap(id:"middle",label:"Middle",width:3333,height:10000,assignment:.drum(38)))
    #expect(Array(added.pads.prefix(2))==bar.pads)
    #expect(added.pads.last?.x==3333)
    #expect(added.pad(x:0.5,y:0.5)?.assignment == .drum(38))
    #expect(bar.addingInGap(id:"large",label:"Large",width:3334,height:10000,assignment:.note(60))==nil)
    #expect(bar.addingInGap(id:"half",label:"Half",width:1000,height:5000,assignment:.note(60))==nil)
    #expect(bar.addingInGap(id:"left",label:"Duplicate",width:1000,height:10000,assignment:.note(60))==nil)
    let grid=try #require(CustomSurfacePadLayout.grid(surface:.tablet,columns:2,rows:2))
    let gap=try #require(grid.removing(id:"pad-4"))
    let filled=try #require(gap.addingInGap(id:"new",label:"New",width:5000,height:5000,assignment:.degree(-2)))
    #expect(filled.pads.last?.x==5000 && filled.pads.last?.y==5000)
    #expect(grid.addingInGap(id:"full",label:"Full",width:1,height:1,assignment:.note(60))==nil)
}

@Test func customSurfaceHitTestingHonorsEveryDecimalBoundary() throws {
    for edge in 1..<10000 {
        let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[
            surfacePad("left",0,0,edge,10000),
            surfacePad("right",edge,0,10000-edge,10000)
        ]))
        let x=Double(edge)/10000
        #expect(layout.pad(x:x,y:0.5)?.id=="right")
        #expect(layout.pad(x:x.nextDown,y:0.5)?.id=="left")
    }
    let y=Double(3)/10000
    let vertical=try #require(CustomSurfacePadLayout(surface:.phone,pads:[
        surfacePad("top",0,0,10000,3),surfacePad("bottom",0,3,10000,9997)
    ]))
    #expect(vertical.pad(x:1,y:y)?.id=="bottom")
    #expect(vertical.pad(x:1,y:y.nextDown)?.id=="top")
    #expect(vertical.pad(x:1,y:1)?.id=="bottom")
}

@Test func customSurfaceStagedGeometryAndReplacementRequireExplicitDecision() {
    let pad=surfacePad("one",0,0,5000,10000,.chord([60,64,67]))
    #expect(!pad.hasStagedEdit(label:"one",x:0,y:0,width:5000,height:10000,replacingAssignment:false))
    #expect(pad.hasStagedEdit(label:"New label",x:0,y:0,width:5000,height:10000,replacingAssignment:false))
    #expect(pad.hasStagedEdit(label:"one",x:100,y:0,width:5000,height:10000,replacingAssignment:false))
    #expect(pad.hasStagedEdit(label:"one",x:0,y:0,width:5000,height:10000,replacingAssignment:true))
    let changed=pad.editingGeometry(label:"New label",x:100,y:0,width:5000,height:10000)
    #expect(changed.assignment==pad.assignment)
    #expect(!changed.hasStagedEdit(label:"New label",x:100,y:0,width:5000,height:10000,replacingAssignment:false))
}

@Test func customSurfaceReplacementReasonsPreserveOriginalAndExactEdges() throws {
    let left=surfacePad("left",0,0,9999,10000)
    let right=surfacePad("right",9999,0,1,10000,.degree(-1408))
    let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[left,right]))
    #expect(layout.replacementFailure(right)==nil)
    #expect(layout.replacing(right)==layout)
    #expect(layout.replacementFailure(surfacePad("other",0,0,1,1)) == .unknownPad)
    #expect(layout.replacementFailure(right.editingGeometry(label:String(repeating:"é",count:33),x:9999,y:0,width:1,height:10000)) == .invalidLabel)
    #expect(layout.replacementFailure(right.editingGeometry(label:"right",x:Int.max,y:0,width:1,height:10000)) == .invalidGeometry)
    #expect(layout.replacementFailure(surfacePad("right",9999,0,1,10000,.note(128))) == .invalidAssignment)
    let overlap=right.editingGeometry(label:"right",x:9998,y:0,width:2,height:10000)
    #expect(layout.replacementFailure(overlap) == .overlaps("left"))
    #expect(layout.replacing(overlap)==nil)
    #expect(layout.pads==[left,right])
    let bar=try #require(CustomSurfacePadLayout(surface:.touchBar,pads:[left,right]))
    #expect(bar.replacementFailure(right.editingGeometry(label:"right",x:9999,y:0,width:1,height:9999)) == .touchBarGeometry)
}
