import AppKit
import ApplicationServices
import PolylocalCore

/// Listens system-wide for the configured shortcuts (default ⌘C C and ⌘⇧C C).
///
/// Double-press shortcuts are never swallowed: every ⌘C still reaches the frontmost app, so its normal
/// copy keeps working and the selection is already on the pasteboard when we fire. Single-press
/// shortcuts (e.g. ⌃⌥T) are consumed so the app does not also act on them.
@MainActor
public final class HotkeyMonitor {
    public enum Action: Hashable, Sendable {
        case translate
        case replace
        case rewrite
    }

    public struct Trigger: Sendable {
        public let action: Action
        public let shortcut: Shortcut
        /// Pasteboard change count before the first press; lets capture tell a fresh copy from stale contents.
        public let pasteboardChangeCount: Int
    }

    public var onTrigger: ((Trigger) -> Void)?

    public struct KeyPress: Sendable {
        public let keyCode: UInt16
        public let modifiers: Shortcut.Modifiers
    }

    /// Sees every key press first; returning true swallows it (inline suggestions use this for Tab/Esc).
    public var interceptor: ((KeyPress) -> Bool)?

    /// Marks events we post ourselves so the tap lets them through untouched.
    nonisolated static let syntheticMarker: Int64 = 0x7472_616E  // "tran"

    /// Posts a plain Tab that bypasses our own interception (for ⌥Tab = "really insert a tab").
    public static func postPlainTab() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: down) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
    public private(set) var isRunning = false

    /// Set to false while the user records a new shortcut in Settings.
    public var isPaused = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var matcher = ShortcutMatcher<Action>(shortcuts: [:])
    private var changeCountAtFirstPress = 0

    public init() {}

    public func setShortcuts(_ shortcuts: [Action: Shortcut]) {
        matcher.shortcuts = shortcuts
    }

    /// Fails when Accessibility (or Input Monitoring) has not been granted.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        // An active (default) tap so single-press shortcuts can be swallowed; everything else passes through.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: info)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
    }

    fileprivate struct KeyEvent: Sendable {
        let type: CGEventType
        let keyCode: Int64
        let isRepeat: Bool
        let flags: CGEventFlags
        let isSynthetic: Bool
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(_ key: KeyEvent) -> Bool {
        if key.type == .tapDisabledByTimeout || key.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard key.type == .keyDown, !key.isSynthetic, !isPaused else { return false }

        var modifiers: Shortcut.Modifiers = []
        if key.flags.contains(.maskControl) { modifiers.insert(.control) }
        if key.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if key.flags.contains(.maskShift) { modifiers.insert(.shift) }
        if key.flags.contains(.maskCommand) { modifiers.insert(.command) }
        let keyCode = UInt16(truncatingIfNeeded: key.keyCode)
        if let interceptor, interceptor(KeyPress(keyCode: keyCode, modifiers: modifiers)) { return true }
        guard !key.isRepeat else { return false }
        // Plain keys go through the matcher too: typing between two ⌘C presses must break the double press.

        let changeCount = NSPasteboard.general.changeCount
        switch matcher.press(keyCode: keyCode, modifiers: modifiers,
                             at: ProcessInfo.processInfo.systemUptime) {
        case .none:
            return false
        case .armed:
            changeCountAtFirstPress = changeCount
            return false
        case .fire(let action, let consume):
            guard let shortcut = matcher.shortcuts[action] else { return false }
            let trigger = Trigger(action: action, shortcut: shortcut,
                                  pasteboardChangeCount: shortcut.doublePress ? changeCountAtFirstPress : changeCount)
            DispatchQueue.main.async { [weak self] in self?.onTrigger?(trigger) }
            return consume
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let key = HotkeyMonitor.KeyEvent(
        type: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        flags: event.flags,
        isSynthetic: event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticMarker)
    // The tap's run loop source lives on the main run loop.
    let swallow = MainActor.assumeIsolated { monitor.handle(key) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
