import Foundation
import Testing
@testable import Polylocal
import PolylocalCore

@MainActor
@Suite struct HistoryStoreTests {
    let en = Language.code("en")!, tr = Language.code("tr")!

    func makeStore() -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        return (HistoryStore(fileURL: url), url)
    }

    func entry(_ text: String, origin: HistoryStore.Entry.Origin, at date: Date) -> HistoryStore.Entry {
        .init(date: date, sourceText: text, translation: "t:\(text)", source: tr, target: en, origin: origin, appName: nil)
    }

    @Test func windowTypingCollapsesIntoOneEntry() {
        let (store, _) = makeStore()
        let now = Date()
        store.add(entry("Mer", origin: .window, at: now))
        store.add(entry("Merhaba", origin: .window, at: now.addingTimeInterval(2)))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].sourceText == "Merhaba")
    }

    @Test func popupEntriesAreKeptSeparately() {
        let (store, _) = makeStore()
        let now = Date()
        store.add(entry("Bir", origin: .popup, at: now))
        store.add(entry("İki", origin: .popup, at: now.addingTimeInterval(1)))
        #expect(store.entries.map(\.sourceText) == ["İki", "Bir"])
    }

    @Test func persistsAndReloads() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.add(entry("Kalıcı", origin: .popup, at: Date()))
        try await Task.sleep(for: .milliseconds(900))
        #expect(HistoryStore(fileURL: url).entries.first?.sourceText == "Kalıcı")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func clearRemovesFile() async throws {
        let (store, url) = makeStore()
        store.add(entry("Sil", origin: .popup, at: Date()))
        try await Task.sleep(for: .milliseconds(900))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
