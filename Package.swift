// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Translater",
    defaultLocalization: "tr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Translater", targets: ["Translater"]),
    ],
    targets: [
        // Pure logic: languages, prompts, engine protocol, catalog types. No AppKit.
        .target(name: "TranslaterCore"),
        // Translation backends: OpenAI-compatible streaming client, llama-server process, Ollama.
        .target(name: "Engines", dependencies: ["TranslaterCore"]),
        // Model catalog, downloads, SHA-256 verification.
        .target(name: "ModelManager", dependencies: ["TranslaterCore"]),
        // Global shortcuts, Accessibility text capture/replace, permissions.
        .target(name: "SystemIntegration", dependencies: ["TranslaterCore"]),
        // Menu bar app.
        .executableTarget(
            name: "Translater",
            dependencies: ["TranslaterCore", "Engines", "ModelManager", "SystemIntegration"]
        ),
        .testTarget(name: "TranslaterCoreTests", dependencies: ["TranslaterCore", "Engines"]),
        .testTarget(name: "ModelManagerTests", dependencies: ["ModelManager"]),
    ]
)
