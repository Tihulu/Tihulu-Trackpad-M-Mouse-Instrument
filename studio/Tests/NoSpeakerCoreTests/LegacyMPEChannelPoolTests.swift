import Testing
@testable import NoSpeakerCore

@Test func mpeAllocationExcludesActiveSustainedAndRetiredChannels() {
    var pool = LegacyMPEChannelPool()
    #expect(pool.next(occupied:[],sustained:[]) == 1)
    let retirement1 = pool.retire(channel:1,sustained:true,fretless:true); #expect(!retirement1)
    let retirement2 = pool.retire(channel:2,sustained:true,fretless:false); #expect(!retirement2)
    #expect(pool.reserved == [1,2])
    #expect(pool.next(occupied:[3],sustained:[4]) == 5)
    #expect(pool.pedalChanged(sustained:[1]) == [])
    #expect(pool.next(occupied:[],sustained:[1]) == 2)
    #expect(pool.pedalChanged(sustained:[]) == [1])
    #expect(pool.next(occupied:[],sustained:[]) == 1)
}
@Test func mpeExhaustionDoesNotStealOrUseReservedDrumChannel() {
    var pool = LegacyMPEChannelPool()
    let members = Set(1...15).subtracting([9])
    for c in members { let retirement3 = pool.retire(channel:c,sustained:true,fretless:true); #expect(!retirement3) }
    #expect(pool.next(occupied:[],sustained:members) == nil)
    #expect(pool.pedalChanged(sustained:members.subtracting([15])) == [15])
    #expect(pool.next(occupied:[],sustained:members.subtracting([15])) == 15)
    #expect(pool.next(occupied:[15],sustained:members.subtracting([15])) == nil)
    let retirement4 = pool.retire(channel:15,sustained:false,fretless:true); #expect(retirement4)
    #expect(pool.pedalChanged(sustained:[]) == members.subtracting([15]).sorted())
}
@Test func mpeRetirementWaitsForLastSustainOwner() {
    var pool = LegacyMPEChannelPool(), sustain = LegacySustainOwners()
    _ = sustain.replace(.touch,channels:[1])
    _ = sustain.replace(.helper,channels:[1])
    let retirement5 = pool.retire(channel:1,sustained:sustain.active.contains(1),fretless:true); #expect(!retirement5)
    _ = sustain.replace(.touch,channels:[])
    #expect(pool.pedalChanged(sustained:sustain.active).isEmpty)
    #expect(pool.next(occupied:[],sustained:sustain.active) == 2)
    _ = sustain.replace(.helper,channels:[])
    #expect(pool.pedalChanged(sustained:sustain.active) == [1])
}
