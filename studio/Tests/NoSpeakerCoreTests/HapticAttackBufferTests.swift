import Testing
@testable import NoSpeakerCore

@Test func hapticAttackBufferPreservesShortIsolatedAttacksExactlyOnce() {
    var buffer = HapticAttackBuffer<Int>()
    for i in 0..<10_000 {
        let now = Double(i)*0.1
        buffer.offer(i,now:now)
        let first = buffer.take(now:now+0.018)
        let next = buffer.take(now:now+0.019)
        #expect(first == i)
        #expect(next == nil)
    }
}
@Test func hapticAttackBufferBoundsAndGroupsRecentAttacks() {
    var buffer = HapticAttackBuffer<Int>()
    for i in 0..<10 { buffer.offer(i,now:1+Double(i)*0.001) }
    let grouped = buffer.drain(now:1.011)
    #expect(grouped == [6,7,8,9])
    #expect(buffer.isEmpty)
}
@Test func hapticAttackBufferRejectsStaleInvalidAndRetiredIntents() {
    var buffer = HapticAttackBuffer<Int>()
    buffer.offer(1,now:1)
    let expired = buffer.take(now:1.05)
    #expect(expired == nil)
    buffer.offer(2,now:2)
    buffer.removeAll()
    let retired = buffer.take(now:2.001)
    #expect(retired == nil)
    buffer.offer(3,now:3)
    let reversed = buffer.drain(now:2.9)
    #expect(reversed.isEmpty)
    buffer.offer(4,now:.nan)
    #expect(buffer.isEmpty)
    buffer.offer(5,now:4)
    let invalid = buffer.take(now:.infinity)
    #expect(invalid == nil && buffer.isEmpty)
}
