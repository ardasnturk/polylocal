import AppKit
import SwiftUI
import PolylocalCore

/// DeepL-style two-pane translator. Translates as you type (debounced).
struct MainWindowView: View {
    let app: AppModel
    @Bindable var translator: TranslatorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pane(header: sourcePicker) {
                    TextEditor(text: $translator.input)
                        .font(.title3)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if translator.input.isEmpty {
                                Text("Type or paste text to translate")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } footer: {
                    if !translator.input.isEmpty {
                        Button("Clear", systemImage: "xmark") { translator.reset(input: "") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Text("\(translator.input.count) characters").foregroundStyle(.tertiary)
                }

                Divider()

                pane(header: targetPicker) {
                    ScrollView {
                        Text(translator.output)
                            .font(.title3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 5)
                    }
                    .overlay(alignment: .topLeading) {
                        if let error = translator.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .padding(.leading, 5)
                        }
                    }
                } footer: {
                    if translator.isTranslating { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translator.output, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(translator.output.isEmpty)
                }
            }
            Divider()
            StatusBar(app: app)
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    private var sourcePicker: some View {
        HStack {
            Picker("Mode", selection: $translator.mode) {
                ForEach(TranslatorModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Source", selection: $translator.sourceOverride) {
                Text(autoLabel).tag(Language?.none)
                Divider()
                ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("Swap languages", systemImage: "arrow.left.arrow.right") { translator.swap() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Swap languages (⇧⌘S)")
        }
    }

    @ViewBuilder
    private var targetPicker: some View {
        if translator.mode == .rewrite {
            HStack {
                RewriteStylePicker(style: $translator.rewriteStyle)
                Spacer()
            }
        } else {
            translationTargetPicker
        }
    }

    private var translationTargetPicker: some View {
        HStack {
            Picker("Target", selection: Binding(get: { translator.target }, set: { translator.targetOverride = $0 })) {
                ForEach(Language.all) { Text($0.localizedName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if translator.target.hasFormality {
                FormalityPicker(formality: $translator.formality)
            }
        }
    }

    private var autoLabel: String {
        if translator.sourceOverride == nil, let detected = translator.source {
            return String(localized: "Automatic (\(detected.localizedName))")
        }
        return String(localized: "Detect automatically")
    }

    private func pane<Header: View, Content: View, Footer: View>(
        header: Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { footer() }.font(.caption).frame(height: 18)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
