import SwiftUI
import PolylocalCore

struct PopupView: View {
    struct Actions {
        var copy: () -> Void
        var replace: () -> Void
        var openMain: () -> Void
        var close: () -> Void
        /// Selecting all of the translation copied it.
        var copied: () -> Void
    }

    @Bindable var translator: TranslatorModel
    let state: PopupController.State
    let settings: AppSettings
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            output
            Text(translator.input)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            footer
        }
        .padding(14)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Mode", selection: $translator.mode) {
                ForEach(TranslatorModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            if translator.mode == .translate {
                Text(sourceLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Picker("Target language", selection: targetBinding) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if translator.target.hasFormality {
                    FormalityPicker(formality: $translator.formality, language: translator.target)
                        .controlSize(.small)
                }
            } else {
                RewriteStylePicker(style: $translator.rewriteStyle)
            }
            Spacer()
            if translator.isTranslating { ProgressView().controlSize(.small) }
            Button(action: actions.close) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .font(.callout)
    }

    @ViewBuilder
    private var output: some View {
        if let error = translator.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TranslationTextView(translator: translator, fontSize: 17) { actions.copied() }
                .frame(height: outputHeight)
        }
    }

    private var footer: some View {
        HStack {
            Button(state.copied ? "Copied" : "Copy", systemImage: state.copied ? "checkmark" : "doc.on.doc",
                   action: actions.copy)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(translator.output.isEmpty)
            if state.canReplace {
                Button("Replace", systemImage: "arrow.uturn.left", action: actions.replace)
                    .keyboardShortcut(state.mode == .replace ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
                    .disabled(translator.output.isEmpty || translator.isTranslating)
            }
            Spacer()
            Button("Open in window", systemImage: "macwindow", action: actions.openMain)
                .keyboardShortcut("o", modifiers: .command)
        }
        .controlSize(.small)
    }

    /// Grows with the text (estimated; the text view does not size itself), up to a scrolling maximum.
    private var outputHeight: CGFloat {
        let lines = translator.output.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 48))) }
        return min(280, max(30, CGFloat(lines) * 23 + 6))
    }

    private var sourceLabel: String {
        if let source = translator.source { return source.localizedName }
        return translator.isTranslating ? String(localized: "Detecting…") : String(localized: "Unknown language")
    }

    private var targetBinding: Binding<Language> {
        Binding(get: { translator.target }, set: { translator.targetOverride = $0 })
    }
}
