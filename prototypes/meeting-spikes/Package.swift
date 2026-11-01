// swift-tools-version: 6.0
import PackageDescription

// Meeting mode spikes (docs/MEETING_MODE.md §6). Throwaway CLIs that answer one question each.
let package = Package(
    name: "meeting-spikes",
    platforms: [.macOS("14.2")],
    targets: [
        // S1: capture one app's audio through a Core Audio process tap, optionally muted for the user.
        .executableTarget(name: "AudioTap", swiftSettings: [.swiftLanguageMode(.v5)]),
        // S4: speak with AVSpeechSynthesizer into a chosen output device without touching the system default.
        .executableTarget(name: "TTSRoute", swiftSettings: [.swiftLanguageMode(.v5)]),
        // S2: speech recognition latency on short phrases.
        .executableTarget(name: "ASRBench", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
