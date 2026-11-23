import NoSpeakerCore

#if os(macOS)
import SwiftUI

@main
struct NoSpeakerStudioApp: App {
    @StateObject private var studio = StudioController()

    var body: some Scene {
        WindowGroup("NoSpeaker Studio") {
            ContentView()
                .environmentObject(studio)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Panic Stop") { studio.panicStop() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
#else
import Foundation

@main
struct NoSpeakerStudioApp {
    static func main() {
        print("NoSpeaker Studio GUI requires macOS. The shared NoSpeakerCore package remains available for tests and tooling.")
    }
}
#endif
