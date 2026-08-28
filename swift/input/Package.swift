// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InputBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "InputBridge",
            path: "Sources/InputBridge"
        )
    ]
)
