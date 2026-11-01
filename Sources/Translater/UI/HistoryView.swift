import SwiftUI
import TranslaterCore

struct HistoryView: View {
    let app: AppModel
    @State private var query = ""
    @State private var selection = Set<HistoryStore.Entry.ID>()
    @State private var confirmClear = false

    var body: some View {
        Group {
            if !app.settings.historyEnabled && app.history.entries.isEmpty {
                ContentUnavailableView {
                    Label("Geçmiş kapalı", systemImage: "clock.badge.xmark")
                } description: {
                    Text("Açarsan çevirilerin yalnızca bu Mac'te saklanır.")
                } actions: {
                    Button("Geçmişi aç") { app.settings.historyEnabled = true }
                }
            } else if app.history.entries.isEmpty {
                ContentUnavailableView("Henüz çeviri yok", systemImage: "clock")
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .searchable(text: $query, placement: .toolbar, prompt: "Geçmişte ara")
        .toolbar {
            ToolbarItem {
                Button("Tümünü sil", systemImage: "trash") { confirmClear = true }
                    .disabled(app.history.entries.isEmpty)
            }
        }
        .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClear) {
            Button("Tümünü sil", role: .destructive) { app.history.clear() }
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
    }

    private var list: some View {
        List(app.history.search(query), selection: $selection) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(entry.source?.localizedName ?? "?") → \(entry.target.localizedName)")
                    if let appName = entry.appName { Text("· \(appName)") }
                    Spacer()
                    Text(entry.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.sourceText).lineLimit(2)
                Text(entry.translation).lineLimit(2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("Pencerede aç") { app.windows.showMain(with: entry.sourceText) }
                Button("Çeviriyi kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.translation, forType: .string)
                }
                Divider()
                Button("Sil", role: .destructive) { app.history.remove([entry.id]) }
            }
        }
        .onDeleteCommand { app.history.remove(selection) }
    }
}
