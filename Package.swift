// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "kawpow-metal",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "kawpow-metal", path: "Sources"),
    ]
)
