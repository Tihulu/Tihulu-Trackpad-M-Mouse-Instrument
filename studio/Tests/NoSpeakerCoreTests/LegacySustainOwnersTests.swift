import Testing
@testable import NoSpeakerCore

private func pedal(_ channel:Int,_ value:Int) -> SensorCommand {
    .init(.init(.sustain,channel:channel),value:value)
}
@Test func legacySustainSameChannelOnlyFirstOnAndLastOff() {
    var s = LegacySustainOwners()
    #expect(s.replace(.touch,channels:[2]) == [pedal(2,127)])
    #expect(s.replace(.helper,channels:[2]).isEmpty)
    #expect(s.replace(.touchBar,channels:[2]).isEmpty)
    #expect(s.replace(.helper,channels:[]).isEmpty)
    #expect(s.replace(.touch,channels:[]).isEmpty)
    #expect(s.active == [2])
    #expect(s.replace(.touchBar,channels:[]) == [pedal(2,0)])
    #expect(s.releaseAll().isEmpty)
}
@Test func legacySustainRemapAndMPEChannelsRemainIndependent() {
    var s = LegacySustainOwners()
    #expect(s.replace(.touch,channels:[1,3]) == [pedal(1,127),pedal(3,127)])
    #expect(s.replace(.helper,channels:[3]).isEmpty)
    #expect(s.replace(.touchBar,channels:[5]) == [pedal(5,127)])
    #expect(s.replace(.helper,channels:[6]) == [pedal(6,127)])
    #expect(s.replace(.touch,channels:[1,3,4]) == [pedal(4,127)])
    #expect(s.replace(.touch,channels:[]) == [pedal(1,0),pedal(3,0),pedal(4,0)])
    #expect(s.releaseAll() == [pedal(5,0),pedal(6,0)])
    #expect(s.active.isEmpty)
}
@Test func legacySustainOwnershipExhaustiveTwoChannelTransitions() {
    let owners: [LegacySustainOwners.Owner] = [.touch,.helper,.touchBar]
    let values: [Set<Int>] = [[],[0],[1],[0,1]]
    for a in values { for b in values { for c in values {
        let initial = [a,b,c]
        for index in 0..<3 { for next in values {
            var state = LegacySustainOwners()
            for i in 0..<3 { _ = state.replace(owners[i],channels:initial[i]) }
            let before = a.union(b).union(c)
            var proposed = initial; proposed[index] = next
            let after = proposed[0].union(proposed[1]).union(proposed[2])
            let expected = before.subtracting(after).sorted().map { pedal($0,0) }
                + after.subtracting(before).sorted().map { pedal($0,127) }
            #expect(state.replace(owners[index],channels:next) == expected)
            #expect(state.active == after)
        }}
    }}}
}
