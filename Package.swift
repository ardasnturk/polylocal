// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Polylocal",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Polylocal", targets: ["Polylocal"]),
    ],
    dependencies: [
        // Auto-update (MIT). Bundled into Contents/Frameworks by scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure logic: languages, prompts, engine protocol, catalog types. No AppKit.
        .target(name: "PolylocalCore"),
        // Translation backends: OpenAI-compatible streaming client, llama-server process, Ollama.
        .target(name: "Engines", dependencies: ["PolylocalCore"]),
        // Model catalog, downloads, SHA-256 verification.
        .target(name: "ModelManager", dependencies: ["PolylocalCore"]),
        // Global shortcuts, Accessibility text capture/replace, permissions.
        .target(name: "SystemIntegration", dependencies: ["PolylocalCore"]),
        // Menu bar app.
        .executableTarget(
            name: "Polylocal",
            dependencies: ["PolylocalCore", "Engines", "ModelManager", "SystemIntegration",
                           .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "PolylocalCoreTests", dependencies: ["PolylocalCore", "Engines"]),
        .testTarget(name: "ModelManagerTests", dependencies: ["ModelManager"]),
        .testTarget(name: "PolylocalAppTests", dependencies: ["Polylocal", "PolylocalCore"]),
    ]
)
