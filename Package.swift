// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdobeEnhancer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AdobeEnhancer",
            path: "Sources/AdobeEnhancer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
