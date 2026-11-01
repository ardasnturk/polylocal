import Foundation

/// Detects a key combination pressed twice within `window` seconds (⌘C+C).
/// Pure logic so it can be unit-tested without an event tap.
public struct DoublePressDetector: Sendable {
    public var window: TimeInterval

    private var last: (time: TimeInterval, variant: Int)?

    public init(window: TimeInterval = 0.4) {
        self.window = window
    }

    /// Feed one press. `variant` distinguishes combinations (e.g. ⌘C vs ⌘⇧C).
    /// Returns true when this press completes a double press.
    public mutating func press(at time: TimeInterval, variant: Int = 0) -> Bool {
        if let last, last.variant == variant, time - last.time <= window, time >= last.time {
            self.last = nil
            return true
        }
        last = (time, variant)
        return false
    }

    public mutating func reset() {
        last = nil
    }
}
