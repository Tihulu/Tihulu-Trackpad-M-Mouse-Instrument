import Testing
@testable import NoSpeakerCore

@Test func sustainSlideLockMomentaryAndDeliberateLatch() {
    var s=SustainSlideLock()
    let a=s.apply(.begin,owner:.screen)
    #expect(a == true)
    let b=s.apply(.end(lock:false),owner:.screen)
    #expect(b == false)
    _=s.apply(.begin,owner:.screen)
    let latched=s.apply(.end(lock:true),owner:.screen)
    #expect(latched == nil)
    #expect(s.phase(.screen) == .locked && s.active)
    let unlock=s.apply(.begin,owner:.screen)
    #expect(unlock == false)
    let end=s.apply(.end(lock:true),owner:.screen)
    #expect(end == nil && !s.active)
}
@Test func sustainSlideLockOwnersAndCancellationAreIsolated() {
    var s=SustainSlideLock()
    _=s.apply(.begin,owner:.screen)
    _=s.apply(.end(lock:true),owner:.screen)
    let native=s.apply(.begin,owner:.native)
    #expect(native == nil)
    let release=s.apply(.end(lock:false),owner:.native)
    #expect(release == nil && s.active)
    let cancelled=s.apply(.cancel,owner:.screen)
    #expect(cancelled == false)
    let stale=s.apply(.end(lock:true),owner:.screen)
    #expect(stale == nil && !s.active)
    _=s.apply(.begin,owner:.native)
    let reset=s.reset()
    #expect(reset == false && !s.active)
}
