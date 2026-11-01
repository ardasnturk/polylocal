import AppKit
import SwiftUI

@main
struct PolylocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Polylocal", systemImage: "character.bubble") {
            MenuContent(app: AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM/SIGINT skip applicationWillTerminate; route them through it so llama-server is stopped too.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        // Menu bar only; also set in Info.plist (LSUIElement) for the bundled app.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

private struct MenuContent: View {
    let app: AppModel

    var body: some View {
        Text(app.engine.status.message)
        if !app.accessibilityTrusted {
            Button("Grant Accessibility access for shortcuts…") { app.requestAccessibility() }
        }
        Divider()
        Button("Translation window") { app.windows.showMain() }
            .keyboardShortcut("t")
        Button("History") { app.windows.showHistory() }
            .keyboardShortcut("y")
        Toggle(shortcutToggleTitle, isOn: Binding(
            get: { app.settings.hotkeysEnabled },
            set: { app.settings.hotkeysEnabled = $0 }))
        Divider()
        meetingMenu
        Divider()
        Button("Settings…") { app.windows.showSettings() }
            .keyboardShortcut(",")
        Button("Setup assistant…") { app.windows.showOnboarding() }
        if app.updater.isAvailable {
            Button("Check for Updates…") { app.updater.checkForUpdates() }
                .disabled(!app.updater.canCheckForUpdates)
        }
        Divider()
        Button("Quit Polylocal") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var meetingMenu: some View {
        if app.meeting.isActive {
            Button(String(localized: "Stop meeting subtitles (\(app.meeting.source?.name ?? ""))")) { app.meeting.stop() }
        } else if MeetingController.isSupported {
            Menu("Meeting subtitles") {
                let apps = MeetingApp.candidates()
                if apps.isEmpty {
                    Text("No meeting app is running")
                }
                ForEach(apps) { source in
                    Button(source.name) { app.meeting.start(source) }
                }
                Divider()
                Button("Meeting settings…") { app.windows.showSettings(tab: .meeting) }
            }
        }
        if app.meeting.isSummarizing {
            Text("Writing the meeting summary…")
        }
        if let folder = app.meeting.lastNotesFolder {
            Button("Open last meeting notes") { NSWorkspace.shared.open(folder) }
        }
    }

    private var shortcutToggleTitle: String {
        if let shortcut = app.settings.translateShortcut { return String(localized: "Shortcuts on (\(shortcut.displayString))") }
        return String(localized: "Shortcuts on")
    }
}
