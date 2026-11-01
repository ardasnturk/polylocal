import SwiftUI
import TranslaterCore

struct PopupView: View {
    struct Actions {
        var copy: () -> Void
        var replace: () -> Void
        var openMain: () -> Void
        var close: () -> Void
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
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(sourceLabel)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Picker("Hedef dil", selection: targetBinding) {
                ForEach(Language.all) { Text($0.localizedName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            if translator.isTranslating { ProgressView().controlSize(.small) }
            Button(action: actions.close) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Kapat (Esc)")
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
            ScrollView {
                Text(translator.output.isEmpty ? " " : translator.output)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 28, maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button(state.copied ? "Kopyalandı" : "Kopyala", systemImage: state.copied ? "checkmark" : "doc.on.doc",
                   action: actions.copy)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(translator.output.isEmpty)
            if state.canReplace {
                Button("Yerine yaz", systemImage: "arrow.uturn.left", action: actions.replace)
                    .keyboardShortcut(state.mode == .replace ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
                    .disabled(translator.output.isEmpty || translator.isTranslating)
            }
            Spacer()
            Button("Pencerede aç", systemImage: "macwindow", action: actions.openMain)
                .keyboardShortcut("o", modifiers: .command)
        }
        .controlSize(.small)
    }

    private var sourceLabel: String {
        if let source = translator.source { return source.localizedName }
        return translator.isTranslating ? "Algılanıyor…" : "Bilinmeyen dil"
    }

    private var targetBinding: Binding<Language> {
        Binding(get: { translator.target }, set: { translator.targetOverride = $0 })
    }
}
