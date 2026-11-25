import Testing
@testable import NoSpeakerCore

private func mailboxFrame(_ hz:Double) -> HapticFrame {
    .init(tones:[.init(frequencyHz:hz)],durationMS:18,level:0.5)
}

@Test func groupHapticMailboxCoalescesAndReleaseReplacesHeldFrame() {
    var mailbox = GroupHapticMailbox(now:1)
    for i in 0..<200 {
        let ok = mailbox.publish(frame:mailboxFrame(220+Double(i)),masterLevel:0.7,now:1+Double(i)*0.001)
        #expect(ok)
    }
    let last = mailbox.read(now:1.2)
    #expect(last?.frame == mailboxFrame(419))
    let released = mailbox.publish(frame:nil,masterLevel:0.7,now:1.21)
    #expect(released)
    let silent = mailbox.read(now:1.22)
    #expect(silent?.frame == nil && !mailbox.retired)
}
@Test func groupHapticMailboxDoesNotRenewAfterStallOrClose() {
    var mailbox = GroupHapticMailbox(now:1)
    _ = mailbox.publish(frame:mailboxFrame(440),masterLevel:1,now:1.01)
    let stale = mailbox.read(now:1.12)
    #expect(stale == nil && mailbox.retired)
    let late = mailbox.publish(frame:mailboxFrame(440),masterLevel:1,now:1.13)
    #expect(!late)
    var other = GroupHapticMailbox(now:2)
    other.close()
    let afterClose = other.publish(frame:mailboxFrame(440),masterLevel:1,now:2.01)
    #expect(!afterClose && other.retired)
}
@Test func groupHapticMailboxMuteAndClockRollbackFailClosed() {
    var mailbox = GroupHapticMailbox(now:1)
    _ = mailbox.publish(frame:mailboxFrame(440),masterLevel:.nan,now:1.01)
    let silent = mailbox.read(now:1.02)
    #expect(silent?.frame == nil && silent?.masterLevel == 0)
    let rollback = mailbox.publish(frame:mailboxFrame(440),masterLevel:1,now:1)
    #expect(!rollback && mailbox.retired)
}
