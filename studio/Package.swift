// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoSpeakerStudio",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "NoSpeakerCore", targets: ["NoSpeakerCore"]),
        .library(name: "NoSpeakerMobileCapture", targets: ["NoSpeakerMobileCapture"]),
        .library(name: "NoSpeakerMac", targets: ["NoSpeakerMac"]),
        .executable(name: "tihulu-mac-instrument-engine", targets: ["TihuluEngineCLI"]),
        .executable(name: "tihulu-mac-instrument-native", targets: ["TihuluNativeCLI"]),
        .executable(name: "NoSpeakerStudio", targets: ["NoSpeakerStudio"])
    ],
    targets: [
        .target(name: "NoSpeakerCore"),
        .target(name: "NoSpeakerMobileCapture", dependencies: ["NoSpeakerCore"]),
        .executableTarget(name: "TihuluEngineCLI", dependencies: ["NoSpeakerCore"]),
        .target(name: "NoSpeakerProcessSignals"),
        .executableTarget(name: "TihuluNativeCLI", dependencies: [
            "NoSpeakerProcessSignals",
            "NoSpeakerCore",
            .target(name: "NoSpeakerMac", condition: .when(platforms: [.macOS]))
        ]),
        .target(
            name: "NoSpeakerMac",
            dependencies: ["NoSpeakerCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("CoreMIDI", .when(platforms: [.macOS])),
                .linkedFramework("GameController", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "NoSpeakerStudio",
            dependencies: [
                "NoSpeakerCore",
                .target(name: "NoSpeakerMac", condition: .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "NoSpeakerCoreTests", dependencies: ["NoSpeakerCore"]),
        .testTarget(name: "NoSpeakerMacTests", dependencies: ["NoSpeakerMac"])
    ]
)
