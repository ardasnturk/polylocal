// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ax-probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AXProbe",
            // Prototype: global C callbacks + main-thread state; strict concurrency not worth it here.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
        ),
    ]
)
