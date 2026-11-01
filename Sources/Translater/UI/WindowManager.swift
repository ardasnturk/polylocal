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
        show("main", title: "Translater", size: NSSize(width: 820, height: 460), resizable: true) {
            MainWindowView(app: self.app, translator: self.app.mainTranslator)
        }
    }

    func showSettings() {
        show("settings", title: "Translater Ayarları", size: NSSize(width: 620, height: 480), resizable: false) {
            SettingsView(app: self.app)
        }
    }

    func showOnboarding() {
        show("onboarding", title: "Translater'a hoş geldin", size: NSSize(width: 560, height: 460), resizable: false) {
            OnboardingView(app: self.app) { [weak self] in self?.close("onboarding") }
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
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: content())
            window.setContentSize(size)
            if resizable { window.contentMinSize = NSSize(width: 560, height: 320) }
            window.center()
            window.setFrameAutosaveName("Translater.\(id)")
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
