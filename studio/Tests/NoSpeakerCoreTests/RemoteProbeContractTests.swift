import Foundation
import Testing
@testable import NoSpeakerCore

@Test func remoteProbeSourceSpecificCapabilitiesWithoutTouch() throws {
    let patch = InstrumentPatch(routes: [
        .init(id:"piano",source:.phone,signal:.pianoKey0,destination:.init(.note,number:60)),
        .init(id:"xy",source:.tablet,signal:.x,destination:.init(.controlChange,number:74))
    ])
    let phone = try RemoteProbeContract.expected(patch:patch,source:.phone)
    let tablet = try RemoteProbeContract.expected(patch:patch,source:.tablet)
    #expect(!phone.touch && phone.piano == 1)
    #expect(tablet.touch && tablet.piano == 0)
    #expect(RemoteProbeContract.acceptsCapabilities(try phone.encoded(),expected:phone))
    #expect(!RemoteProbeContract.acceptsCapabilities(try tablet.encoded(),expected:phone))
    #expect(throws:RemoteTouchError.unavailable) { try RemoteProbeContract.expected(patch:patch,source:.trackpad) }
}
@Test func remoteProbeWithheldMetadataRejectsDisclosureAndReplay() throws {
    let good = #"{"kind":"mapping","version":8,"sequence":2,"page":0,"pages":1,"total":0,"detail":false,"rows":[]}"#
    #expect(RemoteProbeContract.acceptsWithheldMapping(Data(good.utf8),sequence:2))
    for bad in [good.replacingOccurrences(of:"false",with:"true"),
                good.replacingOccurrences(of:"\"sequence\":2",with:"\"sequence\":3"),
                good.replacingOccurrences(of:"\"total\":0",with:"\"total\":1"),
                good.replacingOccurrences(of:"\"page\":0",with:"\"page\":0,\"page\":0")] {
        #expect(!RemoteProbeContract.acceptsWithheldMapping(Data(bad.utf8),sequence:2))
    }
}
@Test func remoteProbeNonTouchHostDiagnosticDoesNotEmitCommands() throws {
    let patch = InstrumentPatch(routes:[.init(id:"pad",source:.phone,signal:.drumPad1,destination:.init(.note,number:36))])
    let expected = try RemoteProbeContract.expected(patch:patch,source:.phone)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true)
    var bridge = RemoteHostBridge()
    let key = Data(repeating:71,count:32), id = UUID()
    _ = bridge.process([.ready],now:1,runtime:&runtime)
    try bridge.issue(secret:key,source:.phone,now:1,runtime:&runtime)
    _ = bridge.process([.invitation(id,key,1)],now:1,runtime:&runtime)
    let query = Data(#"{"version":7,"sequence":1,"kind":"capabilities"}"#.utf8)
    let cap = bridge.process([.frame(id,query,1.1)],now:1.1,runtime:&runtime)
    #expect(cap.commands.isEmpty)
    if case .capabilities(_,let value) = cap.actions.first {
        #expect(RemoteProbeContract.acceptsCapabilities(try value.encoded(),expected:expected))
    } else { Issue.record("Missing capabilities") }
    let map = Data(#"{"version":8,"sequence":2,"kind":"mapping","page":0}"#.utf8)
    let result = bridge.process([.frame(id,map,1.2)],now:1.2,runtime:&runtime)
    #expect(result.commands.isEmpty)
    if case .mapping(_,let value) = result.actions.first {
        #expect(RemoteProbeContract.acceptsWithheldMapping(try value.encoded(),sequence:2))
    } else { Issue.record("Missing mapping") }
    let heartbeat = Data(#"{"version":1,"sequence":3,"kind":"heartbeat"}"#.utf8)
    let last = bridge.process([.frame(id,heartbeat,1.3)],now:1.3,runtime:&runtime)
    #expect(last.commands.isEmpty && last.actions == [.acknowledge(id,true)])
}
