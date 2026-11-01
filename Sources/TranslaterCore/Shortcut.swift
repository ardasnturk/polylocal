import Foundation

/// A user-configurable global shortcut: a key with modifiers, optionally pressed twice (⌘C C).
public struct Shortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Virtual key code (physical key position, layout-independent).
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var doublePress: Bool
    /// Character shown for the key, captured when the shortcut was recorded (layout-aware).
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: Modifiers, doublePress: Bool, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.doublePress = doublePress
        self.keyLabel = keyLabel
    }

    public static let keyC: UInt16 = 8

    public static let defaultTranslate = Shortcut(keyCode: keyC, modifiers: .command, doublePress: true, keyLabel: "C")
    public static let defaultReplace = Shortcut(keyCode: keyC, modifiers: [.command, .shift], doublePress: true, keyLabel: "C")

    public var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        let key = keyLabel.uppercased()
        return doublePress ? "\(symbols)\(key) \(key)" : "\(symbols)\(key)"
    }

    /// True when the first press is the app's own Copy, so the selection is already on the pasteboard.
    public var copiesSelection: Bool {
        doublePress && keyCode == Self.keyC && modifiers == .command
    }

    /// Key codes of standard editing/app shortcuts that must never be swallowed as a single press.
    static let reservedCommandKeys: Set<UInt16> = [
        0,   // A  select all
        1,   // S  save
        6,   // Z  undo
        7,   // X  cut
        8,   // C  copy
        9,   // V  paste
        12,  // Q  quit
        13,  // W  close
        17,  // T  new tab
        45,  // N  new
        31,  // O  open
        35,  // P  print
        3,   // F  find
    ]

    public enum Problem: Equatable, Sendable {
        case needsModifier
        case reservedSystemShortcut
        case sameAsOther
    }

    /// Why this shortcut can't be used, if anything.
    public func problem(conflictingWith other: Shortcut?) -> Problem? {
        if modifiers.isEmpty { return .needsModifier }
        if !doublePress, modifiers == .command, Self.reservedCommandKeys.contains(keyCode) {
            return .reservedSystemShortcut
        }
        // Same key and modifiers would be ambiguous even if only one of them is a double press.
        if let other, other.keyCode == keyCode, other.modifiers == modifiers {
            return .sameAsOther
        }
        return nil
    }
}

/// Matches key presses against the configured shortcuts. Pure logic, unit-tested.
public struct ShortcutMatcher<Action: Hashable & Sendable>: Sendable {
    public enum Result: Equatable, Sendable {
        /// Not ours: pass the event through untouched.
        case none
        /// First half of a double press: pass through, remember the moment.
        case armed
        /// Shortcut completed. `consume` tells the event tap to swallow the key event.
        case fire(Action, consume: Bool)
    }

    public var shortcuts: [Action: Shortcut]
    private var detector: DoublePressDetector

    public init(shortcuts: [Action: Shortcut], window: TimeInterval = 0.4) {
        self.shortcuts = shortcuts
        detector = DoublePressDetector(window: window)
    }

    public mutating func press(keyCode: UInt16, modifiers: Shortcut.Modifiers, at time: TimeInterval) -> Result {
        guard let (action, shortcut) = shortcuts.first(where: {
            $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        }) else {
            detector.reset()
            return .none
        }
        guard shortcut.doublePress else {
            detector.reset()
            return .fire(action, consume: true)
        }
        let variant = Int(keyCode) << 8 | modifiers.rawValue
        return detector.press(at: time, variant: variant) ? .fire(action, consume: false) : .armed
    }
}
