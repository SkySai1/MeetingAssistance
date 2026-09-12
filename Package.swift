// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Homebrew's installed WhisperKit 1.1.0 uses this upstream Swift 6.3
        // MLModelAsset compatibility fix. Pin it for reproducible public APIs.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", revision: "e687e26f1865e881e86be968179b13f09ec1aeea"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .testTarget(
            name: "MeetingAssistantTests",
            dependencies: ["MeetingAssistant"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
