import AppKit
import SwiftUI

/// Floating suggestion under the caret. Never becomes key and ignores the mouse,
/// so typing keeps going to the app underneath.
@MainActor
final class SuggestionPanel {
    @Observable
    final class State {
        var text = ""
        var isLoading = false
        var targetName = ""
    }

    let state = State()
    private lazy var panel = makePanel()

    var isVisible: Bool { panel.isVisible }

    func show(below caret: CGRect) {
        panel.orderFrontRegardless()
        position(below: caret)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Re-anchor after the content grew while streaming.
    func reposition(below caret: CGRect) {
        guard panel.isVisible else { return }
        position(below: caret)
    }

    private func position(below caret: CGRect) {
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(caret.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = CGPoint(x: caret.minX - 12, y: caret.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingController(rootView: SuggestionView(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }
}

private struct SuggestionView: View {
    let state: SuggestionPanel.State

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble").foregroundStyle(.tint)
                Text(state.targetName).foregroundStyle(.secondary)
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("⇥ replace  ·  esc").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            Text(state.text.isEmpty ? "…" : state.text)
                .font(.body)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}
