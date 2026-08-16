// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChatApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AIChatApp",
            path: "Sources/AIChatApp"
        )
    ]
)