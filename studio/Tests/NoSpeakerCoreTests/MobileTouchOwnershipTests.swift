import Testing
@testable import NoSpeakerCore

private func contact(_ id:Int,_ x:Double)->MobileTouchKeys.Contact{.init(id:id,x:x)}

@Test func touchOwnerRequiresRealDownBeforeMoveAndNeverRearmsAfterCancel() throws {
    var owner=try #require(MobileTouchOwnership(authorized:3))
    #expect(owner.update(.moved,contacts:[contact(0,0)])==nil)
    #expect(owner.retired && owner.output.keys==0)
    #expect(owner.update(.began,contacts:[contact(0,0)])==nil)
    var fresh=try #require(MobileTouchOwnership(authorized:3))
    #expect(fresh.update(.began,contacts:[contact(0,0)])?.keys==1)
    #expect(fresh.update(.cancelled,contacts:[])==nil)
    #expect(fresh.retired && fresh.output.keys==0)
}
@Test func touchOwnerTracksSharedNotesAndExactCompleteTransitions() throws {
    var owner=try #require(MobileTouchOwnership(authorized:5))
    #expect(owner.update(.began,contacts:[contact(0,0)])?.keys==1)
    #expect(owner.update(.began,contacts:[contact(0,0),contact(1,0.1)])?.keys==1)
    #expect(owner.update(.moved,contacts:[contact(0,0),contact(1,1)])?.keys==5)
    #expect(owner.update(.ended,contacts:[contact(1,1)])?.keys==4)
    #expect(owner.update(.ended,contacts:[])?.keys==0)
    #expect(!owner.retired)
    #expect(owner.update(.began,contacts:[contact(0,1)])?.keys==4)
}
@Test func touchOwnerRejectsDroppedOrInventedPointerAndInvalidCoordinates() throws {
    for change in [MobileTouchOwnership.Change.moved,.began,.ended] {
        var owner=try #require(MobileTouchOwnership(authorized:3))
        _=owner.update(.began,contacts:[contact(1,0)])
        #expect(owner.update(change,contacts:[contact(2,1)])==nil)
        #expect(owner.retired && owner.output.keys==0)
    }
    var owner=try #require(MobileTouchOwnership(authorized:3))
    _=owner.update(.began,contacts:[contact(1,0)])
    #expect(owner.update(.moved,contacts:[contact(1,1.1)])==nil)
    #expect(owner.output.keys==0)
}
@Test func touchOwnerExplicitRetirementIsIdempotent() throws {
    var owner=try #require(MobileTouchOwnership(authorized:3))
    _=owner.update(.began,contacts:[contact(1,0)])
    #expect(owner.retire().keys==0)
    #expect(owner.retire().keys==0)
    #expect(owner.update(.ended,contacts:[])==nil)
}
