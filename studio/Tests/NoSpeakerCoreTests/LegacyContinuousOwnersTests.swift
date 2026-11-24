import Testing
@testable import NoSpeakerCore

@Test func continuousPriorityRestoresLatestLowerOwnerWithoutDuplicate() {
    let cc = SensorDestination(.controlChange,channel:1,number:74)
    var s = LegacyContinuousOwners()
    #expect(s.set(.touchBar,target:cc,value:.init(20,neutral:0)) == [.init(cc,value:20)])
    #expect(s.set(.helper,target:cc,value:.init(50,neutral:0)) == [.init(cc,value:50)])
    #expect(s.set(.touchBar,target:cc,value:.init(30,neutral:0)).isEmpty)
    #expect(s.set(.helper,target:cc,value:.init(50,neutral:0)).isEmpty)
    #expect(s.release(.helper) == [.init(cc,value:30)])
    #expect(s.release(.helper).isEmpty)
    #expect(s.release(.touchBar) == [.init(cc,value:0)])
}
@Test func continuousBendRangeChangesOnlyWhenEffectiveOwnerChanges() {
    let bend = SensorDestination(.pitchBend,channel:2)
    var s = LegacyContinuousOwners()
    #expect(s.set(.helper,target:bend,value:.init(9000,neutral:8192,bendRange:12)) == [.init(bend,value:9000,bendRange:12)])
    #expect(s.set(.helper,target:bend,value:.init(9200,neutral:8192,bendRange:12)) == [.init(bend,value:9200)])
    #expect(s.set(.touch,target:bend,value:.init(9200,neutral:8192,bendRange:24)) == [.init(bend,value:9200,bendRange:24)])
    #expect(s.release(.touch) == [.init(bend,value:9200,bendRange:12)])
    #expect(s.releaseAll() == [.init(bend,value:8192)])
}
@Test func continuousInvalidSnapshotIsAtomicAndReleaseIsScoped() {
    let cc = SensorDestination(.controlChange,channel:0,number:11)
    let other = SensorDestination(.controlChange,channel:2,number:11)
    let reserved = SensorDestination(.controlChange,channel:0,number:64)
    var s = LegacyContinuousOwners()
    #expect(s.replace(.helper,values:[cc:.init(30,neutral:127),other:.init(40,neutral:127)]) ==
        [.init(cc,value:30),.init(other,value:40)])
    #expect(s.replace(.helper,values:[reserved:.init(1,neutral:0)]).isEmpty)
    #expect(s.values(for:.helper).count == 2)
    #expect(s.release(.helper,channel:0) == [.init(cc,value:127)])
    #expect(s.releaseAll() == [.init(other,value:127)])
}


@Test func continuousTouchRetirementPreservesBendUntilPedalRelease() {
    var pool = LegacyMPEChannelPool(), s = LegacyContinuousOwners()
    let bend = SensorDestination(.pitchBend,channel:3)
    let cc = SensorDestination(.controlChange,channel:3,number:11)
    _ = s.set(.helper,target:bend,value:.init(8800,neutral:8192,bendRange:12))
    _ = s.set(.touch,target:bend,value:.init(12000,neutral:8192,bendRange:24))
    _ = s.set(.touch,target:cc,value:.init(60,neutral:127))
    _ = pool.retire(channel:3,sustained:true,fretless:true)
    #expect(s.set(.helper,target:bend,value:.init(9000,neutral:8192,bendRange:12)).isEmpty)
    let retained = s.values(for:.touch).filter { pool.reserved.contains($0.key.channel) }
    #expect(s.replace(.touch,values:retained).isEmpty)
    let released = pool.pedalChanged(sustained:[])
    #expect(released == [3])
    let updates = s.release(.touch,channel:3)
    #expect(updates.contains(.init(bend,value:9000,bendRange:12)))
    #expect(updates.contains(.init(cc,value:127)))
    #expect(updates.count == 2)
}

@Test func continuousTouchFrameRemovesOnlyMissingControlsAndRestoresHelper() {
    var s = LegacyContinuousOwners()
    let mod = SensorDestination(.controlChange,channel:1,number:1)
    let exp = SensorDestination(.controlChange,channel:1,number:11)
    let next = SensorDestination(.controlChange,channel:2,number:1)
    _ = s.set(.helper,target:exp,value:.init(90,neutral:127))
    _ = s.replace(.touch,values:[mod:.init(30,neutral:0),exp:.init(50,neutral:127),next:.init(80,neutral:0)])
    let changes = s.replace(.touch,values:[mod:.init(30,neutral:0),next:.init(80,neutral:0)])
    #expect(changes == [.init(exp,value:90)])
    #expect(s.release(.touch,channel:1) == [.init(mod,value:0)])
    #expect(s.values(for:.touch).keys.contains(next))
}
