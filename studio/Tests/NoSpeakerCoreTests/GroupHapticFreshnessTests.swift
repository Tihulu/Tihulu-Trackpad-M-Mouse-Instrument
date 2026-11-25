import Testing
@testable import NoSpeakerCore

@Test func groupHapticFreshnessExpiresIndependentlyAndCannotResume() {
    var fence = GroupHapticFreshness()
    let accepted1 = fence.refresh(now:1)
    #expect(accepted1)
    let accepted2 = fence.check(now:1.09)
    #expect(accepted2)
    let accepted3 = fence.check(now:1.101)
    #expect(!accepted3)
    #expect(fence.retired)
    let accepted4 = fence.refresh(now:1.102)
    #expect(!accepted4)
}
@Test func groupHapticRefreshCannotHidePriorStallOrInvalidClock() {
    var fence = GroupHapticFreshness()
    let accepted5 = fence.refresh(now:1)
    #expect(accepted5)
    let accepted6 = fence.refresh(now:1.2)
    #expect(!accepted6)
    var other = GroupHapticFreshness()
    let accepted7 = other.refresh(now:1)
    #expect(accepted7)
    let accepted8 = other.refresh(now:0.9)
    #expect(!accepted8)
    var invalid = GroupHapticFreshness()
    let accepted9 = invalid.refresh(now:.nan)
    #expect(!accepted9)
    #expect(invalid.retired)
}
