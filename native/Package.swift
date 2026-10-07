// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MothNative",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "MothNative", path: ".", exclude: ["Tests"],
                sources: ["Chrome.swift", "BrowserFeatures.swift", "DeveloperTools.swift", "AdBlocker.swift"]),
        .testTarget(name: "MothNativeTests", dependencies: ["MothNative"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
