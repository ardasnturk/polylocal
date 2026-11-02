import AppKit
import SwiftUI
import PolylocalCore

/// DeepL-style two-pane translator. Translates as you type (debounced). Click a word of the translation for
/// alternatives; selecting all of it copies it.
struct MainWindowView: View {
    let app: AppModel
    @Bindable var translator: TranslatorModel
    @State private var copied = false
    @FocusState private var inputFocused: Bool

    private let textSize: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            Divider()
            HStack(spacing: 0) {
                inputPane
                Divider()
                outputPane
            }
            Divider()
            StatusBar(app: app)
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { inputFocused = true }
    }

    // MARK: Language bar

    private var languageBar: some View {
        HStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $translator.mode) {
                    ForEach(TranslatorModel.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 8)
                sourceMenu
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity)

            Button { translator.swap() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Swap languages (⇧⌘S)")
            .disabled(translator.mode == .rewrite)

            HStack {
                Spacer(minLength: 8)
                targetMenu
                Spacer(minLength: 8)
                Button { app.windows.showSettings(tab: .glossary) } label: {
                    Image(systemName: "character.book.closed")
                }
                .buttonStyle(.borderless)
                .help("Glossary: terms that are always translated the same way")
                Button { app.windows.showHistory() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("History")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Source", selection: $translator.sourceOverride) {
                Text("Detect automatically").tag(Language?.none)
                Divider()
                ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(sourceTitle).font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var targetMenu: some View {
        if translator.mode == .rewrite {
            RewriteStylePicker(style: $translator.rewriteStyle)
        } else {
            Menu {
                Picker("Target", selection: Binding(get: { translator.target }, set: { translator.targetOverride = $0 })) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(translator.target.localizedName).font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var sourceTitle: String {
        if translator.mode == .rewrite {
            return translator.source.map { String(localized: "Improve (\($0.localizedName))") } ?? String(localized: "Improve text")
        }
        if let source = translator.sourceOverride { return source.localizedName }
        if let detected = translator.source { return String(localized: "\(detected.localizedName) (detected)") }
        return String(localized: "Detect language")
    }

    // MARK: Input

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $translator.input)
                    .font(.system(size: textSize))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .padding(.trailing, 28)
                if translator.input.isEmpty {
                    Text(translator.mode == .rewrite ? "Type or paste text to improve" : "Type or paste text to translate")
                        .font(.system(size: textSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !translator.input.isEmpty {
                    Button {
                        translator.reset(input: "")
                        inputFocused = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Clear (⌘K)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                SpeakButton(text: translator.input, language: translator.source, id: "main.input")
                if translator.input.isEmpty {
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) { translator.input = text }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Text("\(translator.input.count) characters")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.callout)
            .frame(height: 24)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if translator.mode == .translate, translator.target.hasFormality {
                HStack {
                    FormalityPicker(formality: $translator.formality, language: translator.target)
                        .controlSize(.small)
                    Spacer()
                }
            }
            ZStack(alignment: .topLeading) {
                TranslationTextView(translator: translator, fontSize: textSize) { flashCopied() }
                if let error = translator.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(.leading, 5)
                } else if translator.output.isEmpty, translator.isTranslating {
                    Text("Translating…")
                        .font(.system(size: textSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                SpeakButton(text: translator.output, language: translator.mode == .rewrite ? translator.source : translator.target,
                            id: "main.output")
                if translator.isTranslating {
                    ProgressView().controlSize(.small)
                } else if translator.mode == .translate, !translator.output.isEmpty {
                    Text("Click a word for alternatives")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translator.output, forType: .string)
                    flashCopied()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the translation (⇧⌘C). Selecting all of it copies it too.")
                .disabled(translator.output.isEmpty)
            }
            .font(.callout)
            .frame(height: 28)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
    }

    private func flashCopied() {
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

/// Reads a text aloud; a second click stops it.
struct SpeakButton: View {
    let text: String
    let language: Language?
    let id: String

    var body: some View {
        let speaking = Speaker.shared.speakingID == id
        Button { Speaker.shared.toggle(text, language: language, id: id) } label: {
            Image(systemName: speaking ? "stop.circle" : "speaker.wave.2")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(speaking ? "Stop reading" : "Read aloud")
        .disabled(text.isEmpty)
    }
}

struct StatusBar: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(app.engine.status.message)
            Spacer()
            if !app.accessibilityTrusted {
                Button("Grant Accessibility access for shortcuts") { app.requestAccessibility() }
                    .buttonStyle(.link)
            } else if app.hotkeysActive {
                Text(shortcutHint).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var shortcutHint: String {
        [app.settings.translateShortcut.map { String(localized: "\($0.displayString): translate") },
         app.settings.replaceShortcut.map { String(localized: "\($0.displayString): replace") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var color: Color {
        switch app.engine.status {
        case .ready: .green
        case .starting: .orange
        case .notConfigured: .gray
        case .failed: .red
        }
    }
}
