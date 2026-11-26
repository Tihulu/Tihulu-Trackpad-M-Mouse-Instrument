import Testing
@testable import NoSpeakerCore

@Test func cameraZoomUsesDeviceBoundsAndActualSwitchFactors() throws {
    let range=try #require(MobileCameraZoomRange(minimum:0.5,maximum:8,switches:[4,2,2,.nan,10,0.25]))
    #expect(range.switches == [2,4] && range.defaultFactor == 1)
    #expect(range.contains(0.5) && range.contains(8) && !range.contains(10) && !range.contains(.nan))
    #expect(MobileCameraZoomRange(minimum:0,maximum:5) == nil)
    #expect(MobileCameraZoomRange(minimum:2,maximum:1) == nil)
    let fixed=try #require(MobileCameraZoomRange(minimum:1,maximum:1))
    #expect(fixed.contains(1) && !fixed.contains(1.01))
}
