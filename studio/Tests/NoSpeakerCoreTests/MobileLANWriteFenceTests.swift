import Testing
@testable import NoSpeakerCore

private func tick(_ ms:Int64)->Int64 {ms*1_000_000}

@Test func mobileWriteFenceDeliversEarlyReplyOnlyAfterExactCompletion() throws {
    var fence=MobileLANWriteFence()
    let started1=fence.begin(now:0)
    let lease=try #require(started1)
    #expect(fence.receive("accepted",now:tick(1)) == .wait)
    #expect(fence.isWriting)
    #expect(fence.complete(lease,success:true,now:tick(2)) == .deliver("accepted"))
    #expect(!fence.isWriting)
    #expect(fence.receive("accepted",now:tick(3)) == .deliver("accepted"))
}
@Test func mobileWriteFenceEarlyReplyCannotExtendDeadline() throws {
    var fence=MobileLANWriteFence()
    let started2=fence.begin(now:tick(10))
    let lease=try #require(started2)
    #expect(fence.receive("accepted",now:tick(59)) == .wait)
    #expect(fence.poll(now:tick(59)) == .wait)
    #expect(fence.complete(lease,success:true,now:tick(60)) == .close("Transport write timed out"))
    #expect(fence.begin(now:tick(61)) == nil)
}
@Test func mobileWriteFenceDuplicateOrFailedSendIsTerminal() throws {
    var fence=MobileLANWriteFence()
    let started3=fence.begin(now:0)
    let lease=try #require(started3)
    #expect(fence.receive("accepted",now:1) == .wait)
    #expect(fence.receive("accepted",now:2) == .close("Duplicate early reply"))
    #expect(fence.complete(lease,success:true,now:3) == .close("Write fence retired"))
    var failed=MobileLANWriteFence()
    let started4=failed.begin(now:0)
    let other=try #require(started4)
    #expect(failed.receive("accepted",now:1) == .wait)
    #expect(failed.complete(other,success:false,now:2) == .close("Invalid or failed transport write"))
}
@Test func mobileWriteFenceRejectsStaleCompletionAndOverlappingWrites() throws {
    var fence=MobileLANWriteFence()
    let started5=fence.begin(now:0)
    let old=try #require(started5)
    #expect(fence.complete(old,success:true,now:1) == .wait)
    let started6=fence.begin(now:2)
    let next=try #require(started6)
    #expect(old != next)
    #expect(fence.complete(old,success:true,now:3) == .close("Invalid or failed transport write"))
    var overlap=MobileLANWriteFence()
    let started7=overlap.begin(now:0)
    _=try #require(started7)
    #expect(overlap.begin(now:1) == nil)
    #expect(overlap.poll(now:2) == .close("Write fence retired"))
}
@Test func mobileWriteFenceRejectsOversizeNonAsciiAndClockRollback() throws {
    for reply in [String(repeating:"a",count:RemoteTouchFrame.maximumBytes+1),"acceptedé"] {
        var fence=MobileLANWriteFence()
        #expect(fence.receive(reply,now:0) == .close("Invalid transport reply"))
    }
    var fence=MobileLANWriteFence()
    let started8=fence.begin(now:10)
    _=try #require(started8)
    #expect(fence.poll(now:9) == .close("Invalid transport clock"))
    var retired=MobileLANWriteFence()
    retired.retire()
    #expect(retired.begin(now:0)==nil)
}
