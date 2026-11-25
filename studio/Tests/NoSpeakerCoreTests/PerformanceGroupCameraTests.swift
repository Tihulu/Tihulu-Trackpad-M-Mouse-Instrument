import Foundation
import Testing
@testable import NoSpeakerCore

private func cameraProfile() -> PerformanceGroupProfile {
    .init(groups:[.init(name:"Camera and notes",patch:.init(routes:[
        .init(id:"camera",source:.camera,signal:.x,destination:.init(.controlChange,number:74)),
        .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
    ]))])
}

@Test func groupCameraNeedsTwoFreshFramesAndLossKeepsOtherNotes() throws {
    let profile = cameraProfile()
    var session = try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true,allowCamera:true)
    let cam = try session.bind(.camera,now:0)
    let touch = try session.bind(.trackpad,now:0)
    let hand = try #require(AirHandSample.debugSample(x:0.8,y:0.5,aperture:0.6))
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    _ = session.receiveSurface(.trackpad,token:touch,x:nil,y:nil,size:nil,hostTime:0,now:0,send:sink)
    _ = session.receiveSurface(.trackpad,token:touch,x:0.5,y:0.5,size:0.5,hostTime:0.01,now:0.01,send:sink)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.02,now:0.02,send:sink)
    #expect(output.map { $0.command.value } == [100])
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.1,now:0.1,send:sink)
    #expect(output.map { $0.command.value } == [100,102])
    _ = session.receiveCamera(token:cam,hand:nil,hostTime:0.17,now:0.17,send:sink)
    #expect(output.map { $0.command.value } == [100,102,0])
    #expect(session.activeSessions == 1)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.24,now:0.24,send:sink)
    #expect(output.count == 3)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.31,now:0.31,send:sink)
    #expect(output.last?.command.value == 102)
    #expect(session.activeSessions == 2)
}

@Test func groupCameraCaptureTimeExpiryAndDuplicateSamplesCannotRearm() throws {
    var session = try PerformanceGroupGamepadSession(profile:cameraProfile(),allowSurfaces:true,allowCamera:true)
    let cam = try session.bind(.camera,now:0)
    let hand = try #require(AirHandSample.debugSample(x:0.8,y:0.5,aperture:0.6))
    var output: [Int] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0.command.value); return true }
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.01,now:0.2,send:sink)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.1,now:0.3,send:sink)
    #expect(output == [102])
    _ = session.expire(now:0.46,send:sink)
    #expect(output == [102,0])
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.47,now:0.47,send:sink)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.47,now:0.48,send:sink)
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.49,now:0.49,send:sink)
    #expect(output == [102,0])
    _ = session.receiveCamera(token:cam,hand:hand,hostTime:0.56,now:0.56,send:sink)
    #expect(output == [102,0,102])
}

@Test func groupLiveGainAndSetupControllersRequireExplicitSafeAdmission() throws {
    func profile(_ number:Int,_ response:ContinuousResponse? = nil) -> PerformanceGroupProfile {
        .init(groups:[.init(name:"Controls",patch:.init(routes:[
            .init(id:"cc",source:.lid,signal:.angle,destination:.init(.controlChange,number:number),response:response)
        ]))])
    }
    for number in [0,6,32,38,96,97,98,99,100,101,7,11] {
        #expect(!PerformanceGroupGamepadSession.supports(profile(number),allowScalars:true))
    }
    let safe = profile(7,.init(release:0.35))
    var session = try PerformanceGroupGamepadSession(profile:safe,allowScalars:true)
    let token = try session.bind(.lid,now:0)
    var output: [Int] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0.command.value); return true }
    _ = session.receiveScalar(.lid,token:token,value:0.4,hostTime:0,now:0,send:sink)
    _ = session.panic(send:sink)
    #expect(output == [51,44])
}

@Test func groupCameraOptInDoesNotAdmitNoteOrPedalRoutes() throws {
    #expect(!PerformanceGroupGamepadSession.supports(cameraProfile(),allowSurfaces:true))
    for target in [SensorDestination(.note,number:60),.init(.sustain)] {
        let profile = PerformanceGroupProfile(groups:[.init(name:"Gate",patch:.init(routes:[
            .init(id:"gate",source:.camera,signal:.gesture,destination:target)
        ]))])
        #expect(!PerformanceGroupGamepadSession.supports(profile,allowCamera:true))
    }
}
