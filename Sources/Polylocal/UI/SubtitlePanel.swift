import AppKit
import SwiftUI

/// Floating subtitle bar for meeting mode. Stays above other windows, including full-screen meeting apps,
/// never takes focus, and can be dragged anywhere; its position is remembered.
@MainActor
final class SubtitlePanel {
    private unowned let app: AppModel
    private lazy var panel = makePanel()

    init(app: AppModel) {
        self.app = app
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 860, height: 150)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless, .resizable],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentMinSize = NSSize(width: 420, height: 90)
        panel.contentViewController = NSHostingController(rootView: SubtitleView(app: app, meeting: app.meeting))
        panel.setContentSize(size)
        // Default: bottom center, above the Dock and the meeting app's own controls.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 90))
        }
        panel.setFrameAutosaveName("Polylocal.subtitles")
        return panel
    }
}

private struct SubtitleView: View {
    let app: AppModel
    let meeting: MeetingController
    @State private var hovering = false

    private var fontSize: Double { app.settings.meetingFontSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.9)))
        .environment(\.colorScheme, .dark)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if hovering {
                Button { app.settings.meetingFontSize = max(14, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                Button { app.settings.meetingFontSize = min(44, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                Button { meeting.stop() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Stop meeting mode")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var content: some View {
        // The last two phrases: the newest at the bottom, like TV subtitles.
        let recent = meeting.lines.suffix(2)
        if recent.isEmpty {
            Text(placeholder)
                .font(.system(size: fontSize * 0.75))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recent)) { line in
                    LineView(line: line, fontSize: fontSize, showOriginal: app.settings.meetingShowOriginal,
                             isLatest: line.id == recent.last?.id)
                }
            }
        }
    }

    private var placeholder: String {
        switch meeting.state {
        case .listening: String(localized: "Listening…")
        case .starting(let message), .waiting(let message), .failed(let message): message
        case .idle: ""
        }
    }

    private var statusText: String {
        let name = meeting.source?.name ?? ""
        return switch meeting.state {
        case .listening: name
        case .starting, .waiting: String(localized: "\(name) · not listening yet")
        case .failed: String(localized: "\(name) · stopped")
        case .idle: ""
        }
    }

    private var statusColor: Color {
        switch meeting.state {
        case .listening: .green
        case .starting, .waiting: .orange
        case .failed, .idle: .red
        }
    }
}

private struct LineView: View {
    let line: MeetingController.Line
    let fontSize: Double
    let showOriginal: Bool
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if line.isOwnLanguage {
                Text(line.original)
                    .font(.system(size: fontSize, weight: .medium))
            } else {
                // While the translation streams in, the original stands in for it.
                Text(line.translation.isEmpty ? line.original : line.translation)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(line.translation.isEmpty ? .secondary : .primary)
                if showOriginal, !line.translation.isEmpty {
                    Text(line.original)
                        .font(.system(size: fontSize * 0.6))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(3)
        .opacity(isLatest ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
