// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIChatApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // MarkdownUI: GFM markdown rendering (tables, headings, code, etc.)
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // SwiftMath: native LaTeX typesetting (iosMath Swift port, bundled math
        // fonts) used to render `$...$` / `$$...$$` math returned by AI models.
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3")
    ],
    targets: [
        .executableTarget(
            name: "AIChatApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftMath", package: "SwiftMath")
            ],
            path: "Sources/AIChatApp",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)