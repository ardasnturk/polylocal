import AppKit
import ApplicationServices
import TranslaterCore

/// Listens system-wide for ⌘C+C and ⌘⇧C+C.
///
/// The tap is listen-only: every ⌘C still reaches the frontmost app, so its normal copy keeps working
/// and the selection is already on the pasteboard when we fire.
@MainActor
public final class HotkeyMonitor {
    public enum Action: Sendable {
        case translate   // ⌘C+C
        case replace     // ⌘⇧C+C
    }

    public struct Trigger: Sendable {
        public let action: Action
        /// Pasteboard change count before the first press; lets capture tell a fresh copy from stale contents.
        public let pasteboardChangeCount: Int
    }

    public var onTrigger: ((Trigger) -> Void)?
    public private(set) var isRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoublePressDetector()
    private var changeCountAtFirstPress = 0

    public init() {}

    /// Fails when Accessibility (or Input Monitoring) has not been granted.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
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
    }

    fileprivate func handle(_ key: KeyEvent) {
        if key.type == .tapDisabledByTimeout || key.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard key.type == .keyDown, key.keyCode == 8, !key.isRepeat else { return }  // kVK_ANSI_C (key position)
        let flags = key.flags
        guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else {
            detector.reset()
            return
        }
        let shift = flags.contains(.maskShift)
        let changeCount = NSPasteboard.general.changeCount
        if detector.press(at: ProcessInfo.processInfo.systemUptime, variant: shift ? 1 : 0) {
            let trigger = Trigger(action: shift ? .replace : .translate, pasteboardChangeCount: changeCountAtFirstPress)
            DispatchQueue.main.async { [weak self] in self?.onTrigger?(trigger) }
        } else {
            changeCountAtFirstPress = changeCount
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let key = HotkeyMonitor.KeyEvent(
            type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            flags: event.flags)
        // The tap's run loop source lives on the main run loop.
        MainActor.assumeIsolated { monitor.handle(key) }
    }
    return Unmanaged.passUnretained(event)
}
