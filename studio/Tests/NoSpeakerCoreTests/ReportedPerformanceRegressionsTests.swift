import Testing
@testable import NoSpeakerCore

@Test func reportedSustainOnlyDoesNotResetExistingGainOrOtherPedalOwners() {
    let volume = SensorDestination(.controlChange,channel:0,number:7)
    let expression = SensorDestination(.controlChange,channel:0,number:11)
    var controls = LegacyContinuousOwners()
    var pedals = LegacySustainOwners()
    _ = controls.set(.touchBar,target:volume,value:.init(35,neutral:127))
    _ = controls.set(.touchBar,target:expression,value:.init(48,neutral:127))
    let original = controls.values(for:.touchBar)
    let touchDown = pedals.replace(.touch,channels:[0])
    #expect(touchDown == [.init(.init(.sustain,channel:0),value:127)])

    // Exercise the production expressive policy and the shared pedal owners
    // together. A sustain-only helper must not create any expressive intent.
    for step in 0..<256 {
        let sample = Double(step % 101) / 100
        let intents = HelperPerformancePolicy.controls(x:sample,y:1-sample,size:sample,
            assignments:.sustainOnly,channel:0,bendRange:12,vibratoCC:7,expressionCC:11,
            configureReceiverBendRange:false) ?? [:]
        #expect(intents.isEmpty)
        let expressive = controls.replace(.helper,values:intents)
        #expect(expressive.isEmpty)
        let pedal = pedals.replace(.helper,channels:step % 2 == 0 ? [0] : [])
        #expect(pedal.isEmpty)
        #expect(controls.values(for:.touchBar) == original)
        #expect(pedals.active == [0])
    }
    let helperDown = pedals.replace(.helper,channels:[0])
    #expect(helperDown.isEmpty)
    let touchUp = pedals.replace(.touch,channels:[])
    #expect(touchUp.isEmpty)
    let helperUp = pedals.replace(.helper,channels:[])
    #expect(helperUp == [.init(.init(.sustain,channel:0),value:0)])
    let cleanup = controls.release(.helper)
    #expect(cleanup.isEmpty)
    #expect(controls.values(for:.touchBar) == original)
}
