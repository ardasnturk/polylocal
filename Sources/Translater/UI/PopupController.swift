import AppKit
import SwiftUI
import SystemIntegration
import TranslaterCore

/// The ⌘C+C popup: a non-activating floating panel next to the selection.
/// Non-activating means the source app stays frontmost, so its selection is still there for "Replace".
@MainActor
final class PopupController {
    enum Mode { case translate, replace }

    @Observable
    final class State {
        var mode: Mode = .translate
        var appName: String?
        var canReplace = false
        var copied = false
    }

    private unowned let app: AppModel
    private let translator: TranslatorModel
    private let state = State()
    private var panel: PopupPanel?
    private var captured: CapturedText?
    private var clickMonitor: Any?

    init(app: AppModel) {
        self.app = app
        translator = TranslatorModel(settings: app.settings, engine: app.engine)
        translator.debounce = .zero
        translator.onComplete = { [weak self] request, output in
            self?.app.record(request, output, origin: .popup, appName: self?.state.appName)
        }
    }

    func show(_ captured: CapturedText, mode: Mode) {
        self.captured = captured
        state.mode = mode
        state.appName = captured.appName
        state.canReplace = captured.isReplaceable
        state.copied = false
        translator.reset(input: captured.text)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.position(near: captured.selectionRect)
        panel.orderFrontRegardless()
        panel.makeKey()
        installClickMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func copy() {
        guard !translator.output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translator.output, forType: .string)
        state.copied = true
    }

    func replace() {
        guard let captured, !translator.output.isEmpty, !translator.isTranslating else { return }
        let text = translator.output
        close()
        Task {
            // Let key focus return to the source app before a possible paste fallback.
            try? await Task.sleep(for: .milliseconds(80))
            let result = await TextCapture.replace(captured, with: text)
            Log.capture.notice("replace app=\(captured.bundleID ?? "?", privacy: .public) via=\(result.rawValue, privacy: .public)")
            if result == .failed { NSSound.beep() }
        }
    }

    func openInMainWindow() {
        let text = translator.input
        close()
        app.windows.showMain(with: text)
    }

    private func makePanel() -> PopupPanel {
        let view = PopupView(translator: translator, state: state, settings: app.settings, actions: .init(
            copy: { [weak self] in self?.copy() },
            replace: { [weak self] in self?.replace() },
            openMain: { [weak self] in self?.openInMainWindow() },
            close: { [weak self] in self?.close() }
        ))
        return PopupPanel(content: view)
    }

    private func installClickMonitor() {
        if clickMonitor != nil { return }
        // Global monitors only see clicks in other apps, which is exactly "clicked outside".
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

final class PopupPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }

    /// Below the selection when there is room, otherwise above it; falls back to the mouse position.
    func position(near selection: CGRect?) {
        let anchor = selection ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        layoutIfNeeded()
        let size = frame.size
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if origin.y < visible.minY { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}
