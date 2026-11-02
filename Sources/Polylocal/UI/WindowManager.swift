import AppKit
import SwiftUI

/// AppKit-managed windows. A menu bar (accessory) app needs to show and focus these from anywhere,
/// including the popup, which SwiftUI scenes do not allow outside a view hierarchy.
@MainActor
final class WindowManager {
    private unowned let app: AppModel
    private var windows: [String: NSWindow] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func showMain(with text: String? = nil) {
        if let text { app.mainTranslator.reset(input: text) }
        show("main", title: "Polylocal", size: NSSize(width: 900, height: 500), resizable: true) {
            MainWindowView(app: self.app, translator: self.app.mainTranslator)
        }
    }

    func showHistory() {
        show("history", title: String(localized: "Translation History"), size: NSSize(width: 620, height: 520), resizable: true) {
            HistoryView(app: self.app)
        }
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { app.settingsTab = tab }
        show("settings", title: String(localized: "Polylocal Settings"), size: NSSize(width: 620, height: 480), resizable: false) {
            SettingsView(app: self.app)
        }
    }

    func showOnboarding() {
        show("onboarding", title: String(localized: "Welcome to Polylocal"), size: NSSize(width: 560, height: 460), resizable: false) {
            OnboardingView(app: self.app) { [weak self] in self?.close("onboarding") }
        }
    }

    /// Development aid: the menu bar panel in a window, for screenshots (POLYLOCAL_PANEL_WINDOW).
    func showMenuBarPanelPreview() {
        show("panel-preview", title: "Polylocal", size: NSSize(width: 340, height: 460), resizable: false) {
            MenuBarPanel(app: self.app)
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func show<Content: View>(_ id: String, title: String, size: NSSize, resizable: Bool,
                                     content: () -> Content) {
        let window = windows[id] ?? {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                                  backing: .buffered, defer: false)
            window.title = title
            if id == "main" {
                // The language bar continues the title bar.
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: content())
            window.setContentSize(size)
            if resizable { window.contentMinSize = NSSize(width: 640, height: 360) }
            window.center()
            window.setFrameAutosaveName("Polylocal.\(id)")
            windows[id] = window
            return window
        }()
        // When opened from the menu bar, the closing menu hands focus back to the previous app;
        // activating on the next run loop turn wins that race.
        // Cooperative `activate()` is ignored unless the frontmost app yields, so force it: the user asked for this window.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
