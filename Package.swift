// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChatApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // MarkdownUI: GFM markdown rendering (tables, headings, code, etc.)
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "AIChatApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/AIChatApp"
        )
    ]
)