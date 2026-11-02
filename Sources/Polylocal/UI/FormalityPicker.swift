import SwiftUI
import PolylocalCore

/// Formal/informal switch, shown only for target languages that distinguish them. With a `language` it names
/// the forms the way its speakers do (Auto · Sie · du); without one it is a compact menu.
struct FormalityPicker: View {
    @Binding var formality: Formality
    var language: Language?

    var body: some View {
        if let words = language?.formalityWords {
            Picker("Form of address", selection: $formality) {
                Text("Auto").tag(Formality.automatic)
                Text(words.formal).tag(Formality.formal)
                Text(words.informal).tag(Formality.informal)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Form of address: \(words.formal) (formal) or \(words.informal) (informal). Remembered for each language.")
        } else {
            Picker("Form of address", selection: $formality) {
                ForEach(Formality.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Form of address: formal or informal")
        }
    }
}

/// DeepL Write-style rewrite styles.
struct RewriteStylePicker: View {
    @Binding var style: RewriteStyle

    var body: some View {
        Picker("Style", selection: $style) {
            ForEach(RewriteStyle.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Writing style: correct, fluent, formal, casual or concise")
    }
}
