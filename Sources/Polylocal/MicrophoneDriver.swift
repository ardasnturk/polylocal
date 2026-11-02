import AppKit
import Foundation
import Observation
import SystemIntegration

/// Installs and removes the Polylocal Microphone audio driver (meeting mode level 4). The driver ships inside
/// the app; installing copies it to /Library/Audio/Plug-Ins/HAL and restarts the audio server, which needs an
/// administrator password once (asked for by macOS itself).
@MainActor
@Observable
final class MicrophoneDriver {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/PolylocalMicrophone.driver")

    private(set) var isInstalled = PolylocalMicrophone.isInstalled
    private(set) var isWorking = false
    private(set) var error: String?

    /// The copy inside the app, or the output of scripts/build-mic-driver.sh during development.
    static var bundledURL: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PolylocalMicrophone.driver"))
        }
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("build/mic-driver/PolylocalMicrophone.driver"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isAvailable: Bool { Self.bundledURL != nil }

    func refresh() {
        isInstalled = PolylocalMicrophone.isInstalled
    }

    func install() {
        guard let source = Self.bundledURL else { return }
        let destination = Self.installedURL.path
        run("""
            mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(quoted(destination)) && \
            cp -R \(quoted(source.path)) \(quoted(destination)) && chown -R root:wheel \(quoted(destination)) && \
            killall coreaudiod
            """, expectInstalled: true)
    }

    func uninstall() {
        run("rm -rf \(quoted(Self.installedURL.path)) && killall coreaudiod", expectInstalled: false)
    }

    private func run(_ command: String, expectInstalled: Bool) {
        error = nil
        isWorking = true
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        Task.detached {
            var errorInfo: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            let message = errorInfo?[NSAppleScript.errorMessage] as? String
            let cancelled = (errorInfo?[NSAppleScript.errorNumber] as? Int) == -128
            await MainActor.run {
                if let message, !cancelled { self.error = message }
            }
            // The audio server takes a moment to come back with the new device list.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                let done = await MainActor.run {
                    self.refresh()
                    return self.isInstalled == expectInstalled
                }
                if done || message != nil { break }
            }
            await MainActor.run {
                self.isWorking = false
                Log.meeting.notice("microphone driver \(expectInstalled ? "install" : "uninstall", privacy: .public) installed=\(self.isInstalled, privacy: .public)")
            }
        }
    }

    private func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
