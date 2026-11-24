import Testing
@testable import NoSpeakerCore

@Test func hapticSustainVoiceCacheStaysBoundedAcrossLongPedalHold() {
    var voices = HapticSustainVoices<Int>()
    for id in 0..<100_000 {
        voices.remember(id:String(id),value:id)
    }
    #expect(voices.count == 6)
    #expect(voices.sounding(live:[],includeSustained:true) == [99999,99998,99997,99996,99995,99994])
    voices.removeAll()
    #expect(voices.count == 0)
    #expect(voices.sounding(live:[],includeSustained:true).isEmpty)
}
@Test func hapticSustainVoiceCachePrioritizesLiveAndDeduplicatesContacts() {
    var voices = HapticSustainVoices<Int>()
    for id in 0..<6 { voices.remember(id:String(id),value:id) }
    voices.remember(id:"4",value:44)
    #expect(voices.count == 6)
    let live = [(id:"z",value:90),(id:"4",value:400)]
    #expect(voices.sounding(live:live,includeSustained:true) == [400,90,5,3,2,1])
    #expect(voices.sounding(live:live,includeSustained:false) == [400,90])
    #expect(voices.sounding(live:live,includeSustained:true,permits:{ $0 != 5 && $0 != 90 }) == [400,3,2,1,0])
}
@Test func hapticSustainVoiceCacheNeverExceedsMotorPolyphony() {
    var voices = HapticSustainVoices<Int>()
    voices.remember(id:"old",value:99)
    let live = (0..<10).reversed().map { (id:String($0),value:$0) }
    #expect(voices.sounding(live:live,includeSustained:true) == [0,1,2,3,4,5])
}
