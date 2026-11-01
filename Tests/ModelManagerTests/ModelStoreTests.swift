import Foundation
import Testing
@testable import ModelManager
import TranslaterCore

@MainActor
@Suite struct ModelStoreTests {
    // Small real file from the Gemma 4 repo (~60 MB), used only by the opt-in network test.
    static let smallModel = CatalogModel(
        id: "test-mtp", name: "Test", family: "Test",
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/mtp-gemma-4-E4B-it-Q4_0.gguf")!,
        sha256: "d19a11e4fd5019967d9296f77f4d3e139c8903909f70c3a9cf009c9af4b9b88d",
        sizeBytes: 59_678_240, minRAMGB: 1, tier: .light, promptTemplate: .generic,
        license: .init(name: "Apache 2.0", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!, requiresAcceptance: false),
        summary: "")

    func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("translater-tests-\(UUID().uuidString)")
    }

    @Test func sha256MatchesKnownValue() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ModelStore.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func fileWithoutMarkerIsNotInstalled() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(catalog: [Self.smallModel], directory: dir)
        try Data("partial".utf8).write(to: store.fileURL(for: Self.smallModel))
        store.refresh()
        #expect(store.state(of: Self.smallModel) == .notInstalled)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSLATER_NETWORK_TESTS"] == "1"))
    func downloadsAndVerifies() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(catalog: [Self.smallModel], directory: dir)
        store.download(Self.smallModel)
        var sawProgress = false
        for _ in 0..<600 {
            switch store.state(of: Self.smallModel) {
            case .downloading(let p, _) where p > 0: sawProgress = true
            case .installed, .failed: break
            default: break
            }
            if case .installed = store.state(of: Self.smallModel) { break }
            if case .failed(let message) = store.state(of: Self.smallModel) { Issue.record("failed: \(message)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.state(of: Self.smallModel) == .installed)
        #expect(sawProgress)
        // A fresh store sees it as installed via the marker, without re-hashing.
        #expect(ModelStore(catalog: [Self.smallModel], directory: dir).state(of: Self.smallModel) == .installed)
    }
}
