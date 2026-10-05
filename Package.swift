// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenshotManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ScreenshotManager")
    ],
    swiftLanguageModes: [.v5]
)