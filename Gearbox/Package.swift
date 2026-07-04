// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gearbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Gearbox", path: "Sources/Gearbox")
    ]
)
