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
