import AppKit
import SwiftUI
import PolylocalCore

/// Click, then press a key combination; press it twice quickly to record a double press (⌘C C).
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    /// The other configured shortcuts; a new one must not reuse their keys.
    let others: [Shortcut?]
    let defaultValue: Shortcut?
    let onRecordingChange: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var pending: (shortcut: Shortcut, time: TimeInterval)?
    @State private var finishTask: Task<Void, Never>?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(label)
                        .monospaced()
                        .frame(minWidth: 110)
                        .foregroundStyle(recording ? Color.accentColor : .primary)
                }
                Menu {
                    if let defaultValue {
                        Button("Reset to default (\(defaultValue.displayString))") { set(defaultValue) }
                    }
                    Button("Turn off") { set(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if recording {
                Text("Press twice to record a double press. Cancel: Esc")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if recording { return pending?.shortcut.displayString ?? String(localized: "Press a shortcut…") }
        return shortcut?.displayString ?? String(localized: "Off")
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        problem = nil
        pending = nil
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        finishTask?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending = nil
        if recording { onRecordingChange(false) }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {  // Esc
            stopRecording()
            return
        }
        guard !event.isARepeat else { return }
        let candidate = Shortcut(keyCode: event.keyCode, modifiers: modifiers(of: event), doublePress: false,
                                 keyLabel: keyLabel(for: event))
        // Same combination again within the double-press window → double press.
        if let pending, pending.shortcut == candidate, event.timestamp - pending.time <= 0.4 {
            var double = candidate
            double.doublePress = true
            finish(double)
            return
        }
        pending = (candidate, event.timestamp)
        finishTask?.cancel()
        finishTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            finish(candidate)
        }
    }

    private func finish(_ candidate: Shortcut) {
        finishTask?.cancel()
        stopRecording()
        let issue = others.compactMap { candidate.problem(conflictingWith: $0) }.first
            ?? candidate.problem(conflictingWith: nil)
        switch issue {
        case .needsModifier: problem = String(localized: "At least one modifier key is required (⌘ ⌃ ⌥ ⇧).")
        case .reservedSystemShortcut: problem = String(localized: "\(candidate.displayString) is used by the system; use it as a double press instead.")
        case .sameAsOther: problem = String(localized: "Same keys as another shortcut.")
        case nil: set(candidate)
        }
    }

    private func set(_ value: Shortcut?) {
        problem = nil
        shortcut = value
    }

    private func modifiers(of event: NSEvent) -> Shortcut.Modifiers {
        let flags = event.modifierFlags
        var result: Shortcut.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return chars.isEmpty ? "#\(event.keyCode)" : chars.uppercased()
        }
    }
}
