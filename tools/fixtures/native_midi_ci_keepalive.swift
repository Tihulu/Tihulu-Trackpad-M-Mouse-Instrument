#if os(macOS)
import Foundation
import CoreMIDI
import Darwin

// Disposable CI only. A client without ports or endpoints holds the
// on-demand server alive while isolated test processes come and go.
guard ProcessInfo.processInfo.environment["CI"] == "true",
      ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" else {
    exit(2)
}
var client=MIDIClientRef()
let status=MIDIClientCreateWithBlock("TIHULU CI keepalive" as CFString,&client) { @Sendable _ in }
guard status==noErr,client != 0 else {
    FileHandle.standardError.write(Data("CoreMIDI CI keepalive creation failed: \(status)\n".utf8))
    exit(2)
}
FileHandle.standardOutput.write(Data("CoreMIDI CI keepalive ready\n".utf8))
// The test runner terminates this process with SIGTERM in an EXIT trap.
// CoreMIDI releases its client on process exit. No global server action.
while true {
    Thread.sleep(forTimeInterval:0.25)
}
#else
#error("The CI keepalive requires macOS")
#endif
