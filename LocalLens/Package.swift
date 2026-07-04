// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalLens",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalLens",
            path: "Sources/LocalLens"
        )
    ]
)
