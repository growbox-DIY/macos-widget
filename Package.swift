// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrowBoxWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GrowBoxWidget", path: "Sources/GrowBoxWidget")
    ]
)
