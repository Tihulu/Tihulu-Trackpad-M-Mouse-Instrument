// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TIHULUEngineConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path:"../../studio")],
    targets: [
        .executableTarget(name:"engine-consumer",dependencies:[
            .product(name:"NoSpeakerCore",package:"studio")
        ])
    ]
)
