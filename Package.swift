// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Thon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Thon",
            path: "Sources/Thon"
        )
    ],
    swiftLanguageVersions: [.v5]
)
