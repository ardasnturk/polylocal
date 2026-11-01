import Foundation
import Observation
import TranslaterCore

/// Local translation history (opt-in). A JSON file in Application Support, newest first, capped.
@MainActor
@Observable
final class HistoryStore {
    struct Entry: Codable, Identifiable, Hashable {
        enum Origin: String, Codable { case popup, window }

        var id = UUID()
        var date: Date
        var sourceText: String
        var translation: String
        var source: Language?
        var target: Language
        var origin: Origin
        var appName: String?
    }

    private(set) var entries: [Entry] = []

    static let limit = 500
    /// Typing in the main window yields many partial translations; collapse them into one entry.
    static let windowMergeInterval: TimeInterval = 60

    private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.history.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Translater/history.json")
    }

    func add(_ entry: Entry) {
        let trimmed = entry.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !entry.translation.isEmpty else { return }
        if entry.origin == .window, let last = entries.first, last.origin == .window,
           entry.date.timeIntervalSince(last.date) < Self.windowMergeInterval {
            var merged = entry
            merged.id = last.id
            entries[0] = merged
        } else if let last = entries.first, last.sourceText == entry.sourceText, last.target == entry.target {
            entries[0].translation = entry.translation
            entries[0].date = entry.date
        } else {
            entries.insert(entry, at: 0)
        }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleSave()
    }

    func remove(_ ids: Set<Entry.ID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.sourceText.localizedCaseInsensitiveContains(q) || $0.translation.localizedCaseInsensitiveContains(q)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder.history.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Readable only by this user.
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
