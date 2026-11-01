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
                    TextField("Term", text: $newSource, prompt: Text("e.g. pull request"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Translated term", text: $newTarget, prompt: Text("e.g. PR"))
                    Picker("Language", selection: languageBinding) {
                        ForEach(Language.all) { Text($0.localizedName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add", action: add)
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("When these terms appear in a text, they are always translated this way into the selected language. To keep a brand or product name untranslated, map it to itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.glossary.isEmpty {
                    Text("The glossary is empty.").foregroundStyle(.secondary)
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
                    Text("Terms (\(settings.glossary.count))")
                    Spacer()
                    Button("Import CSV…", action: importCSV).font(.caption)
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

    /// One "term,translation" per line; the language picker above sets the target language.
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = Glossary.parseCSV(text, targetLanguage: languageBinding.wrappedValue)
        app.settings.glossary.append(contentsOf: entries)
        importMessage = String(localized: "\(entries.count) terms added (\(languageBinding.wrappedValue.localizedName)).")
    }
}
