import Testing
@testable import NoSpeakerCore

@Test func groupHapticFreshnessExpiresIndependentlyAndCannotResume() {
    var fence = GroupHapticFreshness()
    #expect(fence.refresh(now:1))
    #expect(fence.check(now:1.09))
    #expect(!fence.check(now:1.101))
    #expect(fence.retired)
    #expect(!fence.refresh(now:1.102))
}
@Test func groupHapticRefreshCannotHidePriorStallOrInvalidClock() {
    var fence = GroupHapticFreshness()
    #expect(fence.refresh(now:1))
    #expect(!fence.refresh(now:1.2))
    var other = GroupHapticFreshness()
    #expect(other.refresh(now:1))
    #expect(!other.refresh(now:0.9))
    var invalid = GroupHapticFreshness()
    #expect(!invalid.refresh(now:.nan))
    #expect(invalid.retired)
}
