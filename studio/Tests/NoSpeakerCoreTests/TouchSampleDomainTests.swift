import Testing
@testable import NoSpeakerCore

@Test func touchSampleDomainRejectsNonfiniteBeforeConversion() {
    for invalid in [Double.nan,.infinity,-.infinity] {
        #expect(TouchSampleDomain.normalize(x:invalid,y:0.5,pressure:0.5) == nil)
        #expect(TouchSampleDomain.normalize(x:0.5,y:invalid,pressure:0.5) == nil)
        #expect(TouchSampleDomain.normalize(x:0.5,y:0.5,pressure:invalid) == nil)
    }
    let clamped = TouchSampleDomain.normalize(x:2,y:-1,pressure:2)
    #expect(clamped?.x == 0.9999 && clamped?.y == 0 && clamped?.pressure == 1)
}
@Test func touchSampleDomainRejectsInvalidConfigWithoutArithmetic() {
    #expect(TouchSampleDomain.validConfiguration(root:60,width:1,span:24,threshold:0.5,level:0.8))
    #expect(!TouchSampleDomain.validConfiguration(root:Int.max,width:1,span:24,threshold:0.5,level:0.8))
    #expect(!TouchSampleDomain.validConfiguration(root:60,width:.nan,span:24,threshold:0.5,level:0.8))
    #expect(!TouchSampleDomain.validConfiguration(root:60,width:1,span:.infinity,threshold:0.5,level:0.8))
    #expect(!TouchSampleDomain.validConfiguration(root:60,width:1,span:24,threshold:-1,level:0.8))
    #expect(!TouchSampleDomain.validConfiguration(root:60,width:1,span:24,threshold:0.5,level:.nan))
}
