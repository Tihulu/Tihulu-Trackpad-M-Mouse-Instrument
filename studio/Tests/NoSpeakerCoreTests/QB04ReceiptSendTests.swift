import Testing
@testable import NoSpeakerCore

// Baseline negative regression: the final synchronous consumer may consume
// the remainder of the receipt window. Reporting success is then incorrect.
@Test func qb04DispatchMustRejectExpiredFinalConsumer() {
    var now=1.01
    var trace:[String]=[]
    let accepted=TouchPublicationAdmission.dispatch(queuedAt:1,now:{now},prepare:{
        trace.append("pedal")
    },touch:{
        trace.append("touch")
    },helper:{
        trace.append("helper")
        now=1+TouchPublicationAdmission.maximumAge
    })
    #expect(trace == ["pedal","touch","helper"])
    #expect(!accepted)
}

// A clock that moves backwards inside a publication must not admit another
// consumer even when both observations independently fit the receipt window.
@Test func qb04DispatchMustRejectRegressingClock() {
    var now=10.10
    var trace:[String]=[]
    let accepted=TouchPublicationAdmission.dispatch(queuedAt:10,now:{now},prepare:{
        trace.append("pedal")
        now=10.05
    },touch:{trace.append("touch")},helper:{trace.append("helper")})
    #expect(!accepted)
    #expect(trace == ["pedal"])
}
