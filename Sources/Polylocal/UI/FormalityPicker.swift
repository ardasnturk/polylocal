import SwiftUI
import PolylocalCore

/// Compact formal/informal switch, shown only for target languages that distinguish them.
struct FormalityPicker: View {
    @Binding var formality: Formality

    var body: some View {
        Picker("Hitap", selection: $formality) {
            ForEach(Formality.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Hitap: resmi (siz/Sie) veya samimi (sen/du)")
    }
}

/// DeepL Write-style rewrite styles.
struct RewriteStylePicker: View {
    @Binding var style: RewriteStyle

    var body: some View {
        Picker("Stil", selection: $style) {
            ForEach(RewriteStyle.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Yazım stili: düzelt, akıcı, resmi, samimi veya kısa")
    }
}
