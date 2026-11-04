// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeTrackpad",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TrackpadGestures", targets: ["TrackpadGestures"])
    ],
    targets: [
        .executableTarget(name: "TrackpadGestures")
    ]
)
