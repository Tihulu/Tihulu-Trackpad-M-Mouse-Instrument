import Foundation
import Testing
@testable import NoSpeakerCore

@Test func duplicateRemoteMembersRejectedAcrossAllVersions() throws {
    let invalid = [
        #"{"version":1,"sequence":1,"kind":"touch","x":0.5,"x":1.5,"y":0.5}"#,
        #"{"version":2,"sequence":1,"kind":"orientation","alpha":0,"beta":0,"gamma":0,"gamma":1}"#,
        #"{"version":3,"sequence":1,"kind":"acceleration","x":0,"y":0,"z":0,"z":1}"#,
        #"{"version":4,"sequence":1,"kind":"drumPads","mask":1,"mask":2}"#,
        #"{"version":5,"sequence":1,"kind":"pianoKeys","mask":1,"\u006dask":2}"#,
        #"{"version":6,"sequence":1,"kind":"pedalboard","mask":1,"levels":[0.5,0,0,0,0,0],"levels":[0.7,0,0,0,0,0]}"#,
        #"{"version":7,"sequence":1,"\u0073equence":2,"kind":"capabilities"}"#,
        #"{"version":7,"version":1,"sequence":1,"kind":"capabilities"}"#,
        #"{"version":7,"sequence":1,"kind":"capabilities","kind":"heartbeat"}"#,
        #"{"version":7,"sequence":1,"kind":"capabilities",}"#,
        #"{"version":7,"sequence":1,"kind":"capabilities"}{}"#
    ]
    for value in invalid {
        #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(Data(value.utf8)) }
    }
    let good = #" { "version" : 6, "sequence":1, "kind":"pedalboard", "mask":1, "levels":[5e-1,0,0,0,0,0] } "#
    #expect(try RemoteTouchFrame.read(Data(good.utf8)).mask == 1)
}

@Test func remoteTouchRequiresMappedTouchSource() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes: RemoteDrumPads.routes()),allowRemote:true)
    let key = Data(repeating:42,count:32)
    try runtime.issueRemotePairing(secret:key,source:.phone,now:1)
    let id = try runtime.admitRemote(secret:key,now:1)
    let release = Data(#"{"version":1,"sequence":1,"kind":"release"}"#.utf8)
    #expect(runtime.receiveRemote(id,bytes:release,now:1.1) == .accepted([]))
    let touch = Data(#"{"version":1,"sequence":2,"kind":"touch","x":0.5,"y":0.5}"#.utf8)
    #expect(runtime.receiveRemote(id,bytes:touch,now:1.2) == .close([]))
    #expect(runtime.remotePeerIDs.isEmpty)
}


@Test func remoteDiscreteTokensAreExactAndBOMRejected() throws {
    let invalid = [
        #"{"version":7,"sequence":1.00000000000000000001,"kind":"capabilities"}"#,
        #"{"version":7.0,"sequence":1,"kind":"capabilities"}"#,
        #"{"version":7,"sequence":1e0,"kind":"capabilities"}"#,
        #"{"version":4,"sequence":1,"kind":"drumPads","mask":254.999999999999999999}"#,
        #"{"version":4,"sequence":1,"kind":"drumPads","mask":-0}"#,
        #"{"version":5,"sequence":1,"kind":"pianoKeys","mask":1e0}"#,
        #"{"version":6,"sequence":1,"kind":"pedalboard","mask":8,"levels":[0,0,0,0.999999999999999999,0,0]}"#,
        #"{"version":6,"sequence":1,"kind":"pedalboard","mask":1,"levels":[0.5,0.0,0,0,0,0]}"#,
        #"{"version":6,"sequence":1,"kind":"pedalboard","mask":8,"levels":[0,0,0,1e0,0,0]}"#
    ]
    for value in invalid {
        #expect(throws: RemoteTouchError.invalidFrame) { try RemoteTouchFrame.read(Data(value.utf8)) }
    }
    let good = #"{"version":7,"sequence":1,"kind":"capabilities"}"#
    #expect(throws: RemoteTouchError.invalidFrame) {
        try RemoteTouchFrame.read(Data([0xef,0xbb,0xbf]) + Data(good.utf8))
    }
    let continuous = #"{"version":6,"sequence":1,"kind":"pedalboard","levels":[5e-1,0,0,1,0,0],"mask":9}"#
    #expect(try RemoteTouchFrame.read(Data(continuous.utf8)).mask == 9)
    let rounded = #"{"version":1,"sequence":1,"kind":"touch","x":1.00000000000000000001,"y":5e-1}"#
    #expect(try RemoteTouchFrame.read(Data(rounded.utf8)).x == 1)
}
