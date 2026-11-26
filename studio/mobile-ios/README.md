# TIHULU iOS/iPadOS diagnostic companion

An isolated SwiftUI application wrapping NoSpeakerMobileCapture. Requires iOS/iPadOS 17 or later. Camera permission is requested explicitly. RGB and supported ARKit scene depth are processed locally; no image recording, network connection or MIDI output. The current app is not a full companion or an App Store/TestFlight distribution.

Open TihuluAirPreview.xcodeproj in Xcode, choose a development team and a physical iPhone/iPad for a locally signed run. A supported device is necessary for LiDAR testing. CI builds generic iOS with signing disabled, archives the unsigned .app with SHA256 and checkout provenance. That archive is **not an installable IPA**. No signing credentials are required or included in CI. Camera, orientation, depth and latency remain hardware acceptance tasks.
