import AppKit
import ApplicationServices

/// A text field in another app, as seen through Accessibility.
@MainActor
public struct FocusedField {
    public let bundleID: String
    public let appName: String?
    public let pid: pid_t
    let element: AXUIElement

    /// Same underlying UI element (AX elements compare by identity via CFEqual).
    public func isSame(as other: FocusedField) -> Bool {
        pid == other.pid && CFEqual(element, other.element)
    }

    public var isSecure: Bool {
        let subrole: String? = AX.attribute(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    public var isEditableText: Bool {
        let role: String? = AX.attribute(element, kAXRoleAttribute)
        let editableRoles: Set<String> = [kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String]
        if let role, editableRoles.contains(role) { return true }
        // Web contenteditable areas report AXWebArea/AXGroup but expose a settable value or selection.
        return AX.isSettable(element, kAXValueAttribute) || AX.isSettable(element, kAXSelectedTextRangeAttribute)
    }

    public var text: String? { AX.attribute(element, kAXValueAttribute) }

    public var selection: NSRange? {
        guard let value: AXValue = AX.attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Caret rectangle in Cocoa screen coordinates.
    public var caretRect: CGRect? {
        guard let selection else { return nil }
        if let rect = AX.bounds(element, NSRange(location: selection.location, length: 0)), rect.height > 0 {
            return rect
        }
        // Many apps return an empty rect for a zero-length range; measure the previous character instead.
        guard selection.location > 0,
              let rect = AX.bounds(element, NSRange(location: selection.location - 1, length: 1)) else { return nil }
        return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
    }

    public func rect(for range: NSRange) -> CGRect? {
        AX.bounds(element, range)
    }

    /// Host of the page when the field lives in a browser (walks up to the AXWebArea and reads AXURL).
    public var webHost: String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            let role: String? = AX.attribute(node, kAXRoleAttribute)
            if role == "AXWebArea", let url: URL = AX.attribute(node, kAXURLAttribute) { return url.host() }
            current = AX.attribute(node, kAXParentAttribute)
        }
        return nil
    }
}

/// Follows the focused text field in apps the caller cares about and reports edits.
///
/// Observes only apps for which `shouldObserve` returns true, so text in other apps is never read.
@MainActor
public final class FocusWatcher {
    public enum Event {
        case edited(FocusedField)
        case focusChanged
    }

    public var shouldObserve: (String) -> Bool = { _ in false }
    public var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedField: AXUIElement?
    private var current: (pid: pid_t, bundleID: String, name: String?)?
    private var activationToken: NSObjectProtocol?

    public init() {}

    public func start() {
        guard activationToken == nil else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontmostApp() }
        }
        attachToFrontmostApp()
    }

    public func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        detach()
    }

    /// Re-evaluate the frontmost app (e.g. after rules changed).
    public func refresh() {
        attachToFrontmostApp()
    }

    public var focusedField: FocusedField? {
        guard let current, let appElement,
              let element: AXUIElement = AX.attribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
        return FocusedField(bundleID: current.bundleID, appName: current.name, pid: current.pid, element: element)
    }

    private func attachToFrontmostApp() {
        detach()
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              shouldObserve(bundleID) else { return }
        let pid = app.processIdentifier
        var observer: AXObserver?
        guard AXObserverCreate(pid, focusWatcherCallback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        // Chromium/Electron build their tree only on request.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        self.appElement = appElement
        current = (pid, bundleID, app.localizedName)
        observeFocusedField()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        observedField = nil
        current = nil
        onEvent?(.focusChanged)
    }

    private func observeFocusedField() {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedField {
            AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
        }
        observedField = nil
        guard let field = focusedField, !field.isSecure else { return }
        if AXObserverAddNotification(observer, field.element, kAXValueChangedNotification as CFString, refcon) == .success {
            observedField = field.element
        }
    }

    fileprivate func handle(notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            observeFocusedField()
            onEvent?(.focusChanged)
        } else if notification == kAXValueChangedNotification as String, let field = focusedField, !field.isSecure {
            onEvent?(.edited(field))
        }
    }
}

private func focusWatcherCallback(observer: AXObserver, element: AXUIElement, notification: CFString,
                                  refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Observer sources are on the main run loop.
    MainActor.assumeIsolated { watcher.handle(notification: name) }
}

/// Small Accessibility helpers shared by the system-integration types.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    /// Bounds of a text range, converted from AX (top-left origin) to Cocoa (bottom-left origin) coordinates.
    static func bounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func setRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
