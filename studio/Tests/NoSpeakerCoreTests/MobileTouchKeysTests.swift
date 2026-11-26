import Testing
@testable import NoSpeakerCore

@Test func touchKeysMapsOnlySparseAssignedKeysAndEdges() throws {
    let piano=try #require(MobileTouchKeys(authorized:(1<<2)|(1<<10)|(1<<24)))
    #expect(piano.keys == [2,10,24])
    #expect(piano.output([.init(id:1,x:0)])?.keys == 1<<2)
    #expect(piano.output([.init(id:1,x:0.5)])?.keys == 1<<10)
    #expect(piano.output([.init(id:1,x:1)])?.keys == 1<<24)
}
@Test func touchKeysAggregatesContactsAndReleasesOnlyUnownedKeys() throws {
    let piano=try #require(MobileTouchKeys(authorized:5))
    #expect(piano.output([.init(id:1,x:0),.init(id:2,x:0.2),.init(id:3,x:1)])?.keys == 5)
    #expect(piano.output([.init(id:2,x:0.2),.init(id:3,x:1)])?.keys == 5)
    #expect(piano.output([.init(id:3,x:1)])?.keys == 4)
    #expect(piano.output([])?.keys == 0)
}
@Test func touchKeysRejectsInvalidContactSnapshotRatherThanClamping() throws {
    let piano=try #require(MobileTouchKeys(authorized:1))
    for x in [Double.nan,.infinity,-0.01,1.01] {
        #expect(piano.output([.init(id:0,x:x)]) == nil)
    }
    #expect(piano.output([.init(id:-1,x:0)]) == nil)
    #expect(piano.output([.init(id:1,x:0),.init(id:1,x:1)]) == nil)
    #expect(piano.output((0...10).map{.init(id:$0,x:0)}) == nil)
    #expect(piano.output((0..<10).map{.init(id:$0,x:0)})?.keys == 1)
    #expect(MobileTouchKeys(authorized:0)==nil)
    #expect(MobileTouchKeys(authorized:1<<25)==nil)
}
