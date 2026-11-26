import Foundation
import Testing
@testable import NoSpeakerCore

private func manifest(piano:String="0",pedals:String="0",touch:String="false",drums:String="0")->Data {
    Data("""
    {"kind":"capabilities","version":7,"touch":\(touch),"tilt":false,"acceleration":false,"rotation":false,"airDrums":false,"drums":\(drums),"piano":\(piano),"pedals":\(pedals)}
    """.utf8)
}
@Test func mobileNativeManifestMatchesHostAndAuthorizesOnlyAssignedLane() throws {
    let host=RemoteCapabilities(touch:false,tilt:false,acceleration:false,rotation:false,airDrums:false,drums:0,piano:145,pedals:0)
    let parsed=try #require(MobileLANCapabilities.parseSingleFamily(host.encoded()))
    let lane=try #require(parsed.keysLane())
    #expect(try RemoteTouchFrame.read(lane.encode(.init(keys:145),sequence:1)).mask==145)
    #expect(throws:RemoteTouchError.invalidFrame){try lane.encode(.init(keys:2),sequence:1)}
    #expect(parsed.helperLane(index:0)==nil)
    let helper=try #require(MobileLANCapabilities.parseSingleFamily(manifest(pedals:"4")))
    #expect(helper.keysLane()==nil)
    #expect(helper.helperLane(index:0)==nil)
    #expect(helper.helperLane(index:3)==nil)
    #expect(try RemoteTouchFrame.read(try #require(helper.helperLane(index:2)).encode(.init(level:0.5),sequence:1)).mask==4)
}
@Test func mobileNativeManifestRejectsUnsupportedFamiliesAndNoncanonicalMasks() {
    for data in [manifest(),manifest(piano:"1",pedals:"1"),manifest(piano:"1",touch:"true"),
                 manifest(piano:"1",drums:"1"),manifest(piano:"33554432"),manifest(pedals:"64"),
                 manifest(pedals:"8"),manifest(piano:"1.0"),manifest(piano:"-0"),manifest(piano:"01"),
                 manifest(piano:"true"),manifest(piano:"1e0"),manifest(piano:"1",touch:"0")] {
        #expect(MobileLANCapabilities.parseSingleFamily(data)==nil)
    }
}
@Test func mobileNativeManifestRejectsDuplicateAndUnknownFields() throws {
    let original=try #require(String(data:manifest(piano:"1"),encoding:.utf8))
    for bad in [original.replacingOccurrences(of:"\"piano\":1",with:"\"piano\":1,\"piano\":2"),
                original.replacingOccurrences(of:"\"piano\":1",with:"\"piano\":1,\"extra\":2"),
                original.replacingOccurrences(of:"\"piano\"",with:#""\u0070iano""#),original+"{}"] {
        #expect(MobileLANCapabilities.parseSingleFamily(Data(bad.utf8))==nil)
    }
}
