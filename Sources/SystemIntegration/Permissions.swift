import AppKit
import ApplicationServices

public enum Permissions {
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt (once per app) that links to the Accessibility pane.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt; the C global is not concurrency-safe in Swift 6.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor
    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
