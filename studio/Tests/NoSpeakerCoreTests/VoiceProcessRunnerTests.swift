import Foundation
import Testing
@testable import NoSpeakerCore

#if os(macOS) || os(Linux)
private func voiceTestSleeper(_ duration: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath:"/bin/sleep")
    process.arguments = [duration]
    return process
}

@Test func voiceProcessCompletesAndPrecancelledWorkDoesNotStart() throws {
    let short = voiceTestSleeper("0.01")
    try VoiceProcessRunner.run(short,cancellation:.init(),timeout:5)
    #expect(!short.isRunning)
    #expect(short.terminationStatus == 0)
    let token = VoiceRenderCancellation()
    token.cancel()
    let retired = voiceTestSleeper("10")
    #expect(throws: CancellationError.self) {
        try VoiceProcessRunner.run(retired,cancellation:token)
    }
    #expect(!retired.isRunning)
}

@Test func voiceProcessCancellationStopsRunningChild() {
    let token = VoiceRenderCancellation()
    let process = voiceTestSleeper("10")
    // Schedule cancellation only after launch, on a dedicated thread rather
    // than the shared test executor that also hosts blocking process tests.
    #expect(throws: CancellationError.self) {
        try VoiceProcessRunner.run(process,cancellation:token,timeout:5,onStarted:{
            #expect(process.isRunning)
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval:0.1)
                token.cancel()
            }
        })
    }
    #expect(!process.isRunning)
}

@Test func voiceProcessTimeoutStopsRunningChild() {
    let process = voiceTestSleeper("10")
    #expect(throws: VoiceProcessError.self) {
        try VoiceProcessRunner.run(process,cancellation:.init(),timeout:0.1)
    }
    #expect(!process.isRunning)
}
#endif
