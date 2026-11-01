import SwiftUI
import PolylocalCore

/// Compact formal/informal switch, shown only for target languages that distinguish them.
struct FormalityPicker: View {
    @Binding var formality: Formality

    var body: some View {
        Picker("Form of address", selection: $formality) {
            ForEach(Formality.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Form of address: formal (Sie/siz) or informal (du/sen)")
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
