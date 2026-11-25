import Foundation
import Testing
@testable import NoSpeakerCore

private let driveTarget = SensorDestination(.controlChange,channel:3,number:80)
private func pedalRoute(_ id:String, _ source:SensorSource = .gamepad1,
                        _ signal:SensorSignal = .padA, _ mode:GamepadPedalMode = .toggle,
                        target:SensorDestination = driveTarget) -> SensorMapping {
    .init(id:id,source:source,signal:signal,destination:target,pedalMode:mode)
}

private func pedalFrame(a:Bool = false,b:Bool = false,trigger:Double = 0) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = a ? 1 : 0
    buttons[1] = b ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[trigger,0],sticks:[0,0,0,0]))
}

@Test func gamepadToggleOnlyChangesOnFreshPressAndClearsOnDisconnect() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[pedalRoute("drive")]))
    let idle = try pedalFrame(), pressed = try pedalFrame(a:true)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1.01).isEmpty)
    for i in 0..<1000 {
        let t = 1.02 + Double(i)*0.01
        let expected = i%2 == 0 ? 127 : 0
        #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:t) == [.init(driveTarget,value:expected)])
        #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:t+0.001).isEmpty)
        #expect(runtime.receiveGamepad(source:.gamepad1,frame:idle,now:t+0.002).isEmpty)
    }
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:11.03) == [.init(driveTarget,value:127)])
    #expect(runtime.releaseGamepad(.gamepad1) == [.init(driveTarget,value:0)])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:11.04).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:idle,now:11.05).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:11.06) == [.init(driveTarget,value:127)])
}

@Test func holdAndToggleShareEffectWithoutPrematureOff() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[pedalRoute("toggle"),pedalRoute("hold",.gamepad2,.padA,.hold)]))
    let idle = try pedalFrame(), pressed = try pedalFrame(a:true)
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1.01) == [.init(driveTarget,value:127)])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1.02).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad2,frame:pressed,now:1.03).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1.04).isEmpty)
    #expect(runtime.releaseGamepad(.gamepad1).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1.05) == [.init(driveTarget,value:0)])
}

@Test func analogTriggerToggleUsesHysteresisAndStallReleases() throws {
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[pedalRoute("trigger",.gamepad1,.padLT)]))
    _ = runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(),now:1)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:0.6),now:1.01) == [.init(driveTarget,value:127)])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:0.5),now:1.02).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:0.6),now:1.03).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:0.4),now:1.04).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:0.6),now:1.05) == [.init(driveTarget,value:0)])
    _ = runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(),now:1.06)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:1),now:1.07) == [.init(driveTarget,value:127)])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:try pedalFrame(trigger:1),now:2) == [.init(driveTarget,value:0)])
}

@Test func pedalRouterPanicAndExplicitReleaseClearLatches() throws {
    var router = SensorRouter()
    try router.configure([pedalRoute("sustain",target:.init(.sustain,channel:2))])
    let session = try router.connect(.gamepad1,now:1)
    let target = SensorDestination(.sustain,channel:2)
    #expect(router.ingest(.init(session:session,signal:.padA,value:1,sequence:1,timestamp:1),now:1) == [.init(target,value:127)])
    #expect(router.releaseSignal(session:session,signal:.padA) == [.init(target,value:0)])
    #expect(router.ingest(.init(session:session,signal:.padA,value:1,sequence:2,timestamp:1.01),now:1.01) == [.init(target,value:127)])
    #expect(router.panic() == [.init(target,value:0)])
    #expect(router.panic().isEmpty)
}

@Test func pedalMappingRejectsAnalogConflictsAndUnsafeTargets() throws {
    let route = pedalRoute("drive")
    for invalid in [pedalRoute("stick",.gamepad1,.padLSX),
                    pedalRoute("remote",.phone,.padA),
                    pedalRoute("gain",target:.init(.controlChange,number:7)),
                    pedalRoute("expression",target:.init(.controlChange,number:11)),
                    pedalRoute("rpn",target:.init(.controlChange,number:101)),
                    pedalRoute("note",target:.init(.note,number:60))] {
        #expect(!InstrumentPatch(routes:[invalid]).isValid)
    }
    let analog = SensorMapping(id:"analog",source:.gamepad2,signal:.padLSX,destination:driveTarget)
    #expect(!InstrumentPatch(routes:[route,analog]).isValid)
    var router = SensorRouter()
    #expect(throws:SensorRouterError.invalidMappings) { try router.configure([route,analog]) }
}

@Test func pedalArchiveAndCopyPreserveModeAndLegacyDefaults() throws {
    let old = SensorMapping(id:"old",source:.gamepad1,signal:.padB,destination:.init(.note,number:60))
    let patch = try GamepadMappingEditor.replace(in:.init(routes:[old]),source:.gamepad1,signal:.padA,
        destinations:[driveTarget],pedalMode:.toggle)
    let decoded = try InstrumentPatch.read(patch.archive())
    #expect(decoded == patch)
    let copied = try GamepadMappingEditor.copy(in:decoded,from:.gamepad1,to:.gamepad2,channel:4)
    #expect(copied.routes.first(where:{$0.source == .gamepad2 && $0.signal == .padA})?.pedalMode == .toggle)
    let legacy = try JSONEncoder().encode(old)
    var json = try #require(JSONSerialization.jsonObject(with:legacy) as? [String:Any])
    json.removeValue(forKey:"pedalMode")
    let restored = try JSONDecoder().decode(SensorMapping.self,from:JSONSerialization.data(withJSONObject:json))
    #expect(restored == old && restored.pedalMode == nil)
}
