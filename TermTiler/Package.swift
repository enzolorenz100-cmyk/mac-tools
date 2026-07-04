// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TermTiler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TermTiler", path: "Sources/TermTiler")
    ]
)
