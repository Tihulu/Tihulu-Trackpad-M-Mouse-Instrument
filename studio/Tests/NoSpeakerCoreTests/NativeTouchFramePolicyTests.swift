import Testing
@testable import NoSpeakerCore

@Test func nativeTouchUnknownDevicesCannotReleaseOrTriggerTrackpad() {
    for count in [Int.min,-1,0,1,32,33,Int.max] {
        for hasData in [false,true] {
            #expect(NativeTouchFramePolicy.decision(knownDevice:false,count:count,hasData:hasData) == .ignoreUnknownDevice)
        }
    }
}

@Test func nativeTouchMalformedKnownFramesReleaseWithoutDecoding() {
    for count in [Int.min,-1,0,33,Int.max] {
        for hasData in [false,true] {
            #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:hasData) == .releaseSurface)
        }
    }
    for count in 1...32 {
        #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:false) == .releaseSurface)
        #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:true) == .decode(count))
    }
}
