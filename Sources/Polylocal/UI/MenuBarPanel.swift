import AppKit
import SwiftUI
import PolylocalCore

/// The menu bar panel: status, a quick translate field, and the app's actions.
struct MenuBarPanel: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @State private var copied = false

    private var translator: TranslatorModel { app.quickTranslator }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            quickTranslate
            Divider()
            VStack(spacing: 1) {
                PanelRow(title: "Translation window", systemImage: "rectangle.split.2x1", hint: "⌘T") {
                    open { app.windows.showMain(with: translator.input.isEmpty ? nil : translator.input) }
                }
                .keyboardShortcut("t")
                PanelRow(title: "History", systemImage: "clock.arrow.circlepath", hint: "⌘Y") {
                    open { app.windows.showHistory() }
                }
                .keyboardShortcut("y")
                meetingRows
            }
            .padding(6)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard shortcuts")
                    Text(shortcutHint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Keyboard shortcuts", isOn: Binding(get: { app.settings.hotkeysEnabled }, set: { app.settings.hotkeysEnabled = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if !app.accessibilityTrusted {
                Button("Grant Accessibility access for shortcuts…") { app.requestAccessibility() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Polylocal").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(app.engine.status.message).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { open { app.windows.showOnboarding() } } label: {
                Image(systemName: "wand.and.stars").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Setup assistant…")
            Button { open { app.windows.showSettings() } } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Settings… (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var quickTranslate: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(translator.source?.localizedName ?? String(localized: "Any language"))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Menu {
                    Picker("Target", selection: Binding(get: { translator.target }, set: { translator.targetOverride = $0 })) {
                        ForEach(Language.all) { Text($0.localizedName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(translator.target.localizedName).fontWeight(.medium)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if translator.target.hasFormality {
                    FormalityPicker(formality: Binding(get: { translator.formality }, set: { translator.formality = $0 }),
                                    language: translator.target)
                        .controlSize(.mini)
                }
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 6) {
                TextField("Quick translate…", text: Binding(get: { translator.input }, set: { translator.input = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                if !translator.input.isEmpty {
                    Button { translator.reset(input: "") } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            if !translator.output.isEmpty || translator.isTranslating || translator.error != nil {
                HStack(alignment: .top, spacing: 6) {
                    Group {
                        if let error = translator.error {
                            Text(error).foregroundStyle(.red)
                        } else if translator.output.isEmpty {
                            Text("Translating…").foregroundStyle(.tertiary)
                        } else {
                            Text(translator.output).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translator.output, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(translator.output.isEmpty)
                    .help("Copy")
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    @ViewBuilder private var meetingRows: some View {
        if app.meeting.isActive {
            PanelRow(title: String(localized: "Stop meeting subtitles (\(app.meeting.source?.name ?? ""))"),
                     systemImage: "stop.circle", tint: .red) { app.meeting.stop() }
        } else if MeetingController.isSupported {
            HStack {
                Text("Meeting subtitles")
                Spacer()
                Button("Settings…") { open { app.windows.showSettings(tab: .meeting) } }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            let apps = Array(MeetingApp.candidates().prefix(4))
            if apps.isEmpty {
                PanelRowLabel(title: String(localized: "No meeting app is running"), systemImage: "captions.bubble",
                              hint: nil, tint: .secondary, trailing: nil)
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { source in
                PanelRow(title: String(localized: "Subtitles for \(source.name)"), systemImage: "captions.bubble") {
                    app.meeting.start(source)
                }
            }
        }
        if app.meeting.isSummarizing {
            PanelRowLabel(title: String(localized: "Writing the meeting summary…"), systemImage: "text.badge.checkmark",
                          hint: nil, tint: nil, trailing: nil)
                .foregroundStyle(.secondary)
        }
        if let folder = app.meeting.lastNotesFolder {
            PanelRow(title: "Open last meeting notes", systemImage: "folder") { NSWorkspace.shared.open(folder) }
        }
    }

    private var footer: some View {
        HStack {
            if app.updater.isAvailable {
                Button("Check for Updates…") { app.updater.checkForUpdates() }
                    .disabled(!app.updater.canCheckForUpdates)
            }
            Spacer()
            Button("Quit Polylocal") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Helpers

    private func open(_ action: @escaping () -> Void) {
        dismiss()
        action()
    }

    private var shortcutHint: String {
        let parts = [app.settings.translateShortcut.map { String(localized: "\($0.displayString): translate") },
                     app.settings.replaceShortcut.map { String(localized: "\($0.displayString): replace") }]
            .compactMap { $0 }
        return parts.isEmpty ? String(localized: "No shortcut set") : parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch app.engine.status {
        case .ready: .green
        case .starting: .orange
        case .notConfigured: .gray
        case .failed: .red
        }
    }
}

/// One action in the panel, highlighted on hover like a menu item.
private struct PanelRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var hint: String?
    var tint: Color?
    let action: () -> Void

    init(title: LocalizedStringKey, systemImage: String, hint: String? = nil, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.hint = hint
        self.tint = tint
        self.action = action
    }

    init(title: String, systemImage: String, hint: String? = nil, tint: Color? = nil, action: @escaping () -> Void) {
        self.init(title: LocalizedStringKey(stringLiteral: title), systemImage: systemImage, hint: hint, tint: tint, action: action)
    }

    var body: some View {
        Button(action: action) {
            PanelRowLabel(title: title, systemImage: systemImage, hint: hint, tint: tint, trailing: nil)
        }
        .buttonStyle(.plain)
    }
}

private struct PanelRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let hint: String?
    let tint: Color?
    let trailing: String?
    @State private var hovered = false

    init(title: LocalizedStringKey, systemImage: String, hint: String?, tint: Color?, trailing: String?) {
        self.title = title
        self.systemImage = systemImage
        self.hint = hint
        self.tint = tint
        self.trailing = trailing
    }

    init(title: String, systemImage: String, hint: String?, tint: Color?, trailing: String?) {
        self.init(title: LocalizedStringKey(stringLiteral: title), systemImage: systemImage, hint: hint, tint: tint, trailing: trailing)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? .accentColor)
                .frame(width: 20)
            Text(title)
            Spacer()
            if let hint { Text(hint).foregroundStyle(.tertiary) }
            if let trailing { Image(systemName: trailing).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
