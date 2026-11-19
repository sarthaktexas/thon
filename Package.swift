// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Thon",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update (Thon ▸ Check for Updates…). Only the packaged Thon.app uses it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Thon",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Thon"
        )
    ],
    swiftLanguageVersions: [.v5]
)
