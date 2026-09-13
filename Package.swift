// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Tachikoma",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        // Core Tachikoma library (lightweight, no MCP or Agent)
        .library(
            name: "Tachikoma",
            targets: ["Tachikoma"]),
        
        // Agent system module (Agent class, sessions, agent-specific features)
        .library(
            name: "TachikomaAgent",
            targets: ["TachikomaAgent"]),
        
        // Audio processing module (transcription, TTS, recording)
        .library(
            name: "TachikomaAudio",
            targets: ["TachikomaAudio"]),
        
        // Optional MCP extension module
        .library(
            name: "TachikomaMCP",
            targets: ["TachikomaMCP"]),
        
        // GPT-5 CLI executable
        .executable(
            name: "gpt5cli",
            targets: ["GPT5CLI"]),
        
        // Universal AI CLI executable
        .executable(
            name: "ai-cli",
            targets: ["AICLI"]),

        // Config/auth helper CLI
        .executable(
            name: "tachikoma",
            targets: ["TachikomaConfigCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
    ],
    targets: [
        // Core Tachikoma module (no MCP dependencies)
        .target(
            name: "Tachikoma",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/Tachikoma",
            swiftSettings: tachikomaSwiftSettings),

        // Agent system module
        .target(
            name: "TachikomaAgent",
            dependencies: [
                "Tachikoma",  // For core types and utilities
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/TachikomaAgent",
            swiftSettings: tachikomaSwiftSettings),

        // Audio processing module
        .target(
            name: "TachikomaAudio",
            dependencies: [
                "Tachikoma",  // For core types and utilities
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/TachikomaAudio",
            swiftSettings: tachikomaSwiftSettings),

        // Optional MCP extension module
        .target(
            name: "TachikomaMCP",
            dependencies: [
                "Tachikoma",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/TachikomaMCP",
            exclude: ["README.md"],
            swiftSettings: tachikomaSwiftSettings),

        // Core tests
        .testTarget(
            name: "TachikomaTests",
            dependencies: [
                "Tachikoma",
                "TachikomaAgent",
                "TachikomaAudio",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/TachikomaTests",
            resources: [
                .process("CLITests/__snapshots__/config_init.txt"),
                .process("CLITests/README.md"),
            ],
            swiftSettings: tachikomaSwiftSettings),

        // MCP tests
        .testTarget(
            name: "TachikomaMCPTests",
            dependencies: [
                "TachikomaMCP",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/TachikomaMCPTests",
            swiftSettings: tachikomaSwiftSettings),
        
        // GPT-5 CLI executable target
        .executableTarget(
            name: "GPT5CLI",
            dependencies: ["Tachikoma"],
            path: "Examples",
            exclude: [
                "AI-CLI",
                "README.md",
                "RealtimeExample.swift",
            ],
            sources: ["GPT5CLI.swift"],
            swiftSettings: tachikomaSwiftSettings),
        
        // Universal AI CLI executable target
        .executableTarget(
            name: "AICLI",
            dependencies: ["Tachikoma"],
            path: "Examples/AI-CLI",
            exclude: [
                "README.md",
            ],
            sources: ["Sources/AI-CLI.swift"],
            swiftSettings: tachikomaSwiftSettings),

        // Config/auth helper CLI target
        .executableTarget(
            name: "TachikomaConfigCLI",
            dependencies: ["Tachikoma"],
            path: "Sources/TachikomaConfigCLI",
            swiftSettings: tachikomaSwiftSettings),
    ],
    swiftLanguageModes: [.v6])

let tachikomaSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]
