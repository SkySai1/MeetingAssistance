// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingAssistantCore", targets: ["MeetingAssistantCore"]),
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"]),
        .executable(name: "MeetingAssistantApp", targets: ["MeetingAssistantApp"]),
    ],
    dependencies: [
        // Homebrew's installed WhisperKit 1.1.0 uses this upstream Swift 6.3
        // MLModelAsset compatibility fix. Pin it for reproducible public APIs.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", revision: "e687e26f1865e881e86be968179b13f09ec1aeea"),
        // Pin the inspected streaming diarization API; TTS normalization is unused.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "c7562faf29f07b7634d2b99d41679c6ff430f3b3", traits: []),
    ],
    targets: [
        // Preserve the existing source paths while enforcing the Core/UI boundary.
        .target(
            name: "MeetingAssistantCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift"), .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetingAssistant",
            exclude: ["CLI.swift", "MeetingAssistant.swift"],
            sources: ["Audio", "Meeting", "Transcription", "Context", "Speakers"]
        ),
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: ["MeetingAssistantCore"],
            path: "Sources/MeetingAssistant",
            exclude: ["Audio", "Meeting", "Transcription", "Context", "Speakers"],
            sources: ["CLI.swift", "MeetingAssistant.swift"]
        ),
        .executableTarget(
            name: "MeetingAssistantApp",
            dependencies: ["MeetingAssistantCore"]
        ),
        .testTarget(
            name: "MeetingAssistantTests",
            dependencies: ["MeetingAssistantCore", "MeetingAssistant", "MeetingAssistantApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
