import AppKit
import ApplicationServices

/// Text taken from another app, plus what we need to write a replacement back.
public struct CapturedText {
    public enum Source: String, Sendable {
        case accessibility, pasteboard, simulatedCopy
    }

    public let text: String
    public let source: Source
    public let appName: String?
    public let bundleID: String?
    /// Selection rectangle in Cocoa screen coordinates (bottom-left origin), when the app reports it.
    public let selectionRect: CGRect?
    /// AX role of the focused element (e.g. AXTextArea, AXWebArea); diagnostics only.
    public let role: String?
    let element: AXUIElement?
    let canWriteSelection: Bool

    /// True when the text can be swapped in place (via AX or a paste).
    public var isReplaceable: Bool { element != nil }
}

/// Reads and replaces selected text in the frontmost app.
///
/// Order of attempts (see docs/ARCHITECTURE.md §4.2): Accessibility first, then the pasteboard the
/// app's own ⌘C just filled, then a simulated ⌘C. Secure text fields are never touched.
@MainActor
public enum TextCapture {
    public static func captureSelection(pasteboardChangeCount: Int, allowSimulatedCopy: Bool) async -> CapturedText? {
        let app = NSWorkspace.shared.frontmostApplication
        if let pid = app?.processIdentifier { enableAccessibilityTree(pid: pid) }
        var element = focusedElement()
        if element == nil {
            // Electron/Chromium build the tree only after the request above; give it one beat.
            try? await Task.sleep(for: .milliseconds(150))
            element = focusedElement()
        }
        if let element, isSecure(element) { return nil }

        let rect = element.flatMap(selectionRect)
        let role: String? = element.flatMap { attribute($0, kAXRoleAttribute) }
        let writable = element.map { isSettable($0, kAXSelectedTextAttribute) } ?? false
        func make(_ text: String, _ source: CapturedText.Source) -> CapturedText {
            CapturedText(text: text, source: source, appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                         selectionRect: rect, role: role, element: element, canWriteSelection: writable)
        }

        if let element, let selected: String = attribute(element, kAXSelectedTextAttribute), !selected.isEmpty {
            return make(selected, .accessibility)
        }
        // The app's own ⌘C lands asynchronously; give it a moment.
        for _ in 0..<5 {
            if NSPasteboard.general.changeCount != pasteboardChangeCount,
               let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                return make(text, .pasteboard)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if allowSimulatedCopy, let text = await copyViaSimulatedShortcut() {
            return make(text, .simulatedCopy)
        }
        return nil
    }

    public enum ReplaceResult: String, Sendable {
        case accessibility, paste, failed
    }

    /// Replaces the captured selection with `text`.
    @discardableResult
    public static func replace(_ captured: CapturedText, with text: String) async -> ReplaceResult {
        if let element = captured.element, captured.canWriteSelection {
            let before: String? = attribute(element, kAXValueAttribute)
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            let after: String? = attribute(element, kAXValueAttribute)
            // Web views often report success but ignore the write.
            if status == .success, before == nil || before != after { return .accessibility }
        }
        guard captured.element != nil else { return .failed }
        await paste(text)
        return .paste
    }

    /// Replaces `range` (UTF-16, as AX reports it) in a watched field. Used by inline suggestions.
    @discardableResult
    public static func replace(range: NSRange, in field: FocusedField, with text: String) async -> ReplaceResult {
        let element = field.element
        guard AX.setRange(element, range) else { return .failed }
        let before: String? = attribute(element, kAXValueAttribute)
        if isSettable(element, kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            let after: String? = attribute(element, kAXValueAttribute)
            if before == nil || before != after { return .accessibility }
        }
        // Range is selected; a paste replaces it in web views that ignore AX writes.
        await paste(text)
        return .paste
    }

    // MARK: Pasteboard helpers

    private static func copyViaSimulatedShortcut() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postShortcut(key: 8, flags: .maskCommand)  // ⌘C
        var result: String?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            if pb.changeCount != before { result = pb.string(forType: .string); break }
        }
        restore(saved, to: pb)
        return result?.isEmpty == false ? result : nil
    }

    /// nspasteboard.org markers: clipboard managers (Raycast, Maccy, Alfred…) skip items carrying them,
    /// so our temporary writes never land in the user's clipboard history.
    private static let transientTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    private static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in transientTypes { item.setData(Data(), forType: type) }
        pb.clearContents()
        pb.writeObjects([item])
        postShortcut(key: 9, flags: .maskCommand)  // ⌘V
        try? await Task.sleep(for: .milliseconds(400))
        restore(saved, to: pb)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pb: NSPasteboard) {
        // Putting the user's own contents back should not show up as a new history entry either.
        for item in items {
            for type in transientTypes { item.setData(Data(), forType: type) }
        }
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private static func postShortcut(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: Accessibility helpers

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Asks the frontmost app first: the system-wide query fails with -25204 on macOS 27 (Faz 0 finding).
    private static func focusedElement() -> AXUIElement? {
        var roots: [AXUIElement] = []
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            roots.append(AXUIElementCreateApplication(pid))
        }
        roots.append(AXUIElementCreateSystemWide())
        for root in roots {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    /// Chromium and Electron only build their accessibility tree when asked.
    private static func enableAccessibilityTree(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func selectionRect(_ element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // AX uses a top-left origin on the primary screen; Cocoa uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
