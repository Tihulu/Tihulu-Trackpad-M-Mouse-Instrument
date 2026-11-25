// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoSpeakerStudio",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NoSpeakerCore", targets: ["NoSpeakerCore"]),
        .executable(name: "tihulu-engine", targets: ["TihuluEngineCLI"]),
        .executable(name: "NoSpeakerStudio", targets: ["NoSpeakerStudio"])
    ],
    targets: [
        .target(name: "NoSpeakerCore"),
        .executableTarget(name: "TihuluEngineCLI", dependencies: ["NoSpeakerCore"]),
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
