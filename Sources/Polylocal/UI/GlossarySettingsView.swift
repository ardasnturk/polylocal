import AppKit
import SwiftUI
import PolylocalCore
import UniformTypeIdentifiers

struct GlossarySettingsView: View {
    let app: AppModel
    @State private var newSource = ""
    @State private var newTarget = ""
    @State private var newLanguage: Language?
    @State private var importMessage: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                HStack {
                    TextField("Terim", text: $newSource, prompt: Text("ör. pull request"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Çevirisi", text: $newTarget, prompt: Text("ör. PR"))
                    Picker("Dil", selection: languageBinding) {
                        ForEach(Language.all) { Text($0.localizedName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Ekle", action: add)
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("Bu terimler, metinde geçtiğinde seçilen dile hep bu şekilde çevrilir. Marka ve ürün adlarını çevrilmeden bırakmak için terimi kendisiyle eşleştir.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.glossary.isEmpty {
                    Text("Sözlük boş.").foregroundStyle(.secondary)
                }
                ForEach(settings.glossary) { entry in
                    HStack {
                        Text(entry.source)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(entry.target)
                        Spacer()
                        Text(entry.targetLanguage.localizedName).font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            settings.glossary.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Terimler (\(settings.glossary.count))")
                    Spacer()
                    Button("CSV içe aktar…", action: importCSV).font(.caption)
                }
            } footer: {
                if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var languageBinding: Binding<Language> {
        Binding(get: { newLanguage ?? app.settings.secondaryLanguage }, set: { newLanguage = $0 })
    }

    private func add() {
        app.settings.glossary.append(GlossaryEntry(
            source: newSource.trimmingCharacters(in: .whitespaces),
            target: newTarget.trimmingCharacters(in: .whitespaces),
            targetLanguage: languageBinding.wrappedValue))
        newSource = ""
        newTarget = ""
    }

    /// One "terim,çevirisi" per line; the language picker above sets the target language.
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = Glossary.parseCSV(text, targetLanguage: languageBinding.wrappedValue)
        app.settings.glossary.append(contentsOf: entries)
        importMessage = "\(entries.count) terim eklendi (\(languageBinding.wrappedValue.localizedName))."
    }
}
