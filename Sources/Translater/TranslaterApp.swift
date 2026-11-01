import AppKit
import SwiftUI

@main
struct TranslaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Translater", systemImage: "character.bubble") {
            MenuContent(app: AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            Button("Kısayollar için Erişilebilirlik izni ver…") { app.requestAccessibility() }
        }
        Divider()
        Button("Çeviri penceresi") { app.windows.showMain() }
            .keyboardShortcut("t")
        Toggle("Kısayollar açık (⌘C C)", isOn: Binding(
            get: { app.settings.hotkeysEnabled },
            set: { app.settings.hotkeysEnabled = $0 }))
        Divider()
        Button("Ayarlar…") { app.windows.showSettings() }
            .keyboardShortcut(",")
        Button("Kurulum asistanı…") { app.windows.showOnboarding() }
        Divider()
        Button("Translater'dan çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
