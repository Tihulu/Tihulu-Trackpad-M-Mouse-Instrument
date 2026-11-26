import Testing
@testable import NoSpeakerCore

@Test func physicalPatchReleasesLiftAndWatchdogWithoutDroppingOtherSource() throws {
    let note = SensorDestination(.note, number: 60)
    let patch = InstrumentPatch(routes: [
        .init(id: "a", source: .trackpad, signal: .contact, destination: note),
        .init(id: "b", source: .magicMouse, signal: .contact, destination: note)
    ])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let a = runtime.receive(source: .trackpad, x: 0.2, y: 0.3, size: 0.4, hostTime: 1, now: 1)
    #expect(a == [.init(note, value: 100)])
    let b = runtime.receive(source: .magicMouse, x: 0.5, y: 0.3, size: 0.4, hostTime: 1.1, now: 1.1)
    #expect(b.isEmpty)
    let lift = runtime.receive(source: .trackpad, x: nil, y: nil, size: nil, hostTime: 1.2, now: 1.2)
    #expect(lift.isEmpty)
    #expect(runtime.activeSources == [.magicMouse])
    let expired = runtime.expire(now: 1.5)
    #expect(expired == [.init(note, value: 0)])
    #expect(runtime.activeSources.isEmpty)
}

@Test func physicalPatchRejectsFakePressureAndStaleFrames() throws {
    var patch = InstrumentPatch.starter
    patch.routes[0].signal = .pressure
    #expect(!PhysicalPatchRuntime.supports(patch))
    patch = .starter
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let stale = runtime.receive(source: .trackpad, x: 0.2, y: 0.3, size: 0.4, hostTime: 1, now: 2)
    #expect(stale.isEmpty && runtime.activeSources.isEmpty)
    let fresh = runtime.receive(source: .trackpad, x: 0.25, y: 0.3, size: 0.4, hostTime: 2, now: 2)
    #expect(fresh.contains { $0.destination.kind == .note && $0.value == 100 })
    let stopped = runtime.stop()
    #expect(stopped.contains { $0.destination.kind == .note && $0.value == 0 })
    let after = runtime.receive(source: .trackpad, x: 0.3, y: 0.3, size: 0.4, hostTime: 3, now: 3)
    #expect(after.isEmpty)
}

@Test func physicalPatchReceiptAdmissionRejectsFutureNonfiniteAndExpiredSamples() {
    #expect(PhysicalPatchRuntime.admitsPhysicalReceipt(0,now:0))
    #expect(PhysicalPatchRuntime.admitsPhysicalReceipt(0,now:0.349))
    #expect(!PhysicalPatchRuntime.admitsPhysicalReceipt(0,now:0.35))
    #expect(!PhysicalPatchRuntime.admitsPhysicalReceipt(0.01,now:0))
    #expect(!PhysicalPatchRuntime.admitsPhysicalReceipt(-0.01,now:0))
    #expect(!PhysicalPatchRuntime.admitsPhysicalReceipt(.nan,now:0))
    #expect(!PhysicalPatchRuntime.admitsPhysicalReceipt(0,now:.infinity))
}

@Test func physicalPatchDelayedSecondFrameCannotAdmitStaleNote() throws {
    let a=SensorDestination(.note,number:60),b=SensorDestination(.note,number:64)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:a),
        .init(id:"b",source:.magicMouse,signal:.contact,destination:b)
    ]))
    let first=runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:0,now:0.34)
    #expect(first==[.init(a,value:100)])
    let late=runtime.receive(source:.magicMouse,x:0.5,y:0.5,size:0.5,hostTime:0,now:0.35)
    #expect(late.isEmpty && runtime.activeSources==[.trackpad])
    let released=runtime.stop()
    #expect(released==[.init(a,value:0)])
}


@Test func physicalGamepadCaptureReceiptIsNotRenewedByDelayedSnapshotRead() throws {
    let note=SensorDestination(.note,number:60)
    var state=PhysicalPatchRuntime()
    try state.configure(.init(routes:[.init(id:"n",source:.gamepad1,signal:.padA,destination:note)]))
    let neutral=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons=Array(repeating:0.0,count:12);buttons[0]=1
    let held=try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    #expect(state.receiveGamepad(source:.gamepad1,frame:neutral,now:1).isEmpty)
    #expect(state.receiveGamepad(source:.gamepad1,frame:held,now:1.02,hostTime:1.01)==[.init(note,value:100)])
    #expect(state.receiveGamepad(source:.gamepad1,frame:held,now:1.3,hostTime:1.02).isEmpty)
    #expect(state.expire(now:1.38)==[.init(note,value:0)])
    #expect(state.receiveGamepad(source:.gamepad1,frame:neutral,now:2,hostTime:1.5).isEmpty)
    #expect(state.receiveGamepad(source:.gamepad1,frame:held,now:2.01).isEmpty)
    #expect(state.receiveGamepad(source:.gamepad1,frame:neutral,now:2.02).isEmpty)
    #expect(state.receiveGamepad(source:.gamepad1,frame:held,now:2.03)==[.init(note,value:100)])
    #expect(state.receiveGamepad(source:.gamepad1,frame:held,now:2.04,hostTime:2.02)==[.init(note,value:0)])
}


@Test func physicalSurfaceFreshSnapshotCannotRenewExpiredOwnershipBeforeWatchdog() throws {
    let a=SensorDestination(.note,number:60),b=SensorDestination(.note,number:64)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:a),
        .init(id:"b",source:.magicMouse,signal:.contact,destination:b)
    ]))
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1,now:1)==[.init(a,value:100)])
    #expect(runtime.receive(source:.magicMouse,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2)==[.init(b,value:100)])
    let late=runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.36,now:1.36)
    #expect(late==[.init(a,value:0)] && runtime.activeSources==[.magicMouse])
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.35,now:1.37).isEmpty)
    #expect(runtime.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:1.38,now:1.38)==[.init(a,value:100)])
    #expect(runtime.activeSources==[.trackpad,.magicMouse])
}


@Test func physicalGamepadExpiredSharedOwnersAreReleasedWithoutTransientRestore() throws {
    let target=SensorDestination(.controlChange,number:74)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"high",source:.gamepad1,signal:.padLT,destination:target,priority:10),
        .init(id:"low",source:.gamepad2,signal:.padLT,destination:target,priority:0)
    ]))
    let neutral=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    let high=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0.8,0],sticks:[0,0,0,0]))
    let low=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0.3,0],sticks:[0,0,0,0]))
    _=runtime.receiveGamepad(source:.gamepad1,frame:neutral,now:1)
    _=runtime.receiveGamepad(source:.gamepad2,frame:neutral,now:1)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.01).count==1)
    _=runtime.receiveGamepad(source:.gamepad2,frame:low,now:1.02)
    #expect(runtime.activeSources==[.gamepad1,.gamepad2])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.38)==[.init(target,value:0)])
    #expect(runtime.activeSources.isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.39).isEmpty)
    _=runtime.receiveGamepad(source:.gamepad1,frame:neutral,now:1.4)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.41).count==1)
}


@Test func physicalOrdinaryReleaseAndExpiredOwnerAreRemovedTogether() throws {
    for scalar in [false,true] {
        let target=SensorDestination(.controlChange,number:74)
        let high:SensorSource=scalar ? .lid : .trackpad
        let low:SensorSource=scalar ? .touchBar : .magicMouse
        var runtime=PhysicalPatchRuntime()
        try runtime.configure(.init(routes:[
            .init(id:"high",source:high,signal:scalar ? .angle : .x,destination:target,priority:10),
            .init(id:"low",source:low,signal:.x,destination:target,priority:0)
        ]))
        func input(_ source:SensorSource,_ value:Double?,_ time:Double)->[SensorCommand] {
            if scalar { return runtime.receiveScalar(source:source,value:value,hostTime:time,now:time) }
            return runtime.receive(source:source,x:value,y:value,size:value,hostTime:time,now:time)
        }
        #expect(input(low,0.3,1).count==1)
        #expect(input(high,0.8,1.2).count==1)
        #expect(input(high,nil,1.36)==[.init(target,value:0)])
        #expect(runtime.activeSources.isEmpty)
    }
}

@Test func physicalGamepadDisconnectAndExpiredOwnerAreRemovedTogether() throws {
    let target=SensorDestination(.controlChange,number:74)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"high",source:.gamepad1,signal:.padLT,destination:target,priority:10),
        .init(id:"low",source:.gamepad2,signal:.padLT,destination:target,priority:0)
    ]))
    let neutral=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    let high=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0.8,0],sticks:[0,0,0,0]))
    let low=try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0.3,0],sticks:[0,0,0,0]))
    _=runtime.receiveGamepad(source:.gamepad1,frame:neutral,now:1)
    _=runtime.receiveGamepad(source:.gamepad2,frame:neutral,now:1)
    _=runtime.receiveGamepad(source:.gamepad2,frame:low,now:1.01)
    _=runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.2)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:nil,now:1.37)==[.init(target,value:0)])
    #expect(runtime.activeSources.isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.38).isEmpty)
}


@Test func physicalGamepadBatchDisconnectPreservesSurvivorWithoutRestoringDepartures() throws {
    let target=SensorDestination(.controlChange,number:74)
    var runtime=PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"high",source:.gamepad1,signal:.padLT,destination:target,priority:10),
        .init(id:"mid",source:.gamepad2,signal:.padLT,destination:target,priority:5),
        .init(id:"low",source:.gamepad3,signal:.padLT,destination:target,priority:0)
    ]))
    func snapshot(_ trigger:Double) throws -> GamepadFrame {
        try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[trigger,0],sticks:[0,0,0,0]))
    }
    let neutral=try snapshot(0), high=try snapshot(0.8), mid=try snapshot(0.6), low=try snapshot(0.3)
    for source in [SensorSource.gamepad1,.gamepad2,.gamepad3] {
        _=runtime.receiveGamepad(source:source,frame:neutral,now:1)
    }
    _=runtime.receiveGamepad(source:.gamepad3,frame:low,now:1.01)
    _=runtime.receiveGamepad(source:.gamepad2,frame:mid,now:1.02)
    _=runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.03)
    #expect(runtime.activeSources==[.gamepad1,.gamepad2,.gamepad3])
    let released=runtime.releaseGamepads([.gamepad1,.gamepad2],now:1.04)
    #expect(released.count==1 && released.first?.destination==target)
    #expect(released.first?.value==38)
    #expect(runtime.activeSources==[.gamepad3])
    #expect(runtime.receiveGamepad(source:.gamepad1,frame:high,now:1.05).isEmpty)
    #expect(runtime.receiveGamepad(source:.gamepad2,frame:mid,now:1.05).isEmpty)
}
