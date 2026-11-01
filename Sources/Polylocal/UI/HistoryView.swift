import SwiftUI
import PolylocalCore

struct HistoryView: View {
    let app: AppModel
    @State private var query = ""
    @State private var selection = Set<HistoryStore.Entry.ID>()
    @State private var confirmClear = false

    var body: some View {
        Group {
            if !app.settings.historyEnabled && app.history.entries.isEmpty {
                ContentUnavailableView {
                    Label("History is off", systemImage: "clock.badge.xmark")
                } description: {
                    Text("If you turn it on, translations are stored only on this Mac.")
                } actions: {
                    Button("Turn on history") { app.settings.historyEnabled = true }
                }
            } else if app.history.entries.isEmpty {
                ContentUnavailableView("No translations yet", systemImage: "clock")
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .searchable(text: $query, placement: .toolbar, prompt: "Search history")
        .toolbar {
            ToolbarItem {
                Button("Delete all", systemImage: "trash") { confirmClear = true }
                    .disabled(app.history.entries.isEmpty)
            }
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { app.history.clear() }
        } message: {
            Text("This cannot be undone.")
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
                Button("Open in window") { app.windows.showMain(with: entry.sourceText) }
                Button("Copy translation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.translation, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { app.history.remove([entry.id]) }
            }
        }
        .onDeleteCommand { app.history.remove(selection) }
    }
}
