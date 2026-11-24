import Foundation
import Testing
@testable import NoSpeakerCore

@Test func ensembleTemplatesAreNativeBoundedAndArchiveSafe() throws {
    for preset in EnsemblePreset.allCases {
        let patch = try #require(preset.patch())
        #expect(patch.isValid)
        #expect(patch.routes.count <= SensorRouter.maxMappings)
        #expect(PhysicalPatchRuntime.supports(patch,allowRemote:true))
        #expect(try InstrumentPatch.read(patch.archive()) == patch)
        #expect(Set(patch.routes.filter{$0.source == .tablet}.map(\.destination.channel)) == [1])
        #expect(Set(patch.routes.filter{$0.source == .trackpad}.map(\.destination.channel)) == [2])
        #expect(Set(patch.routes.filter{$0.source == .phone}.map(\.destination.channel)) == [preset == .chamber ? 0 : 9])
    }
}

@Test func ensemblePlayersReleaseIndependentlyAndConductorIsScoped() throws {
    let patch = try #require(EnsemblePreset.chamber.patch())
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch,allowRemote:true)
    let secret = Data(repeating:41,count:32)
    try runtime.issueRemotePairing(secret:secret,source:.phone,now:1,mappingDetails:true)
    let phone = try runtime.admitRemote(secret:secret,now:1)
    try runtime.issueRemotePairing(secret:secret,source:.tablet,now:1.01,mappingDetails:true)
    let tablet = try runtime.admitRemote(secret:secret,now:1.01)
    #expect(runtime.reservedRemoteSessions == 2)
    #expect(try runtime.remoteMappingPage(phone,page:0,sequence:1).rows.allSatisfy { $0[2] == 0 })
    #expect(try runtime.remoteMappingPage(tablet,page:0,sequence:1).rows.allSatisfy { $0[2] == 1 })
    let keys = Data(#"{"version":5,"sequence":1,"kind":"pianoKeys","mask":1}"#.utf8)
    let a = SensorDestination(.note,channel:0,number:48)
    let b = SensorDestination(.note,channel:1,number:48)
    #expect(runtime.receiveRemote(phone,bytes:keys,now:1.02) == .accepted([.init(a,value:100)]))
    #expect(runtime.receiveRemote(tablet,bytes:keys,now:1.03) == .accepted([.init(b,value:100)]))
    let open = AirHandSample.debugSample(x:0.5,y:0.3,aperture:0.8)
    _ = runtime.receiveHelperHands(left:open,right:nil,hostTime:1.04,now:1.04)
    let expression = runtime.receiveHelperHands(left:open,right:nil,hostTime:1.11,now:1.11)
    #expect(Set(expression.map(\.destination)) == [.init(.controlChange,channel:0,number:11),.init(.controlChange,channel:1,number:11)])
    #expect(runtime.releaseCamera().allSatisfy { $0.destination.kind == .controlChange })
    #expect(runtime.revokeRemote(phone) == [.init(a,value:0)])
    #expect(runtime.revokeRemote(tablet) == [.init(b,value:0)])
}
