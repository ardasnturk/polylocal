import Foundation
import Testing
@testable import Engines
import TranslaterCore

/// Opt-in: TRANSLATER_TEST_GGUF=/path/model.gguf swift test
/// Any small GGUF works (e.g. llama.cpp's stories15M test model); output quality is not checked.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRANSLATER_TEST_GGUF"] != nil))
struct LlamaServerTests {
    @Test func startsStreamsAndStops() async throws {
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRANSLATER_TEST_GGUF"]!)
        let server = LlamaServer(modelPath: path)
        try await server.start(contextSize: 512)
        #expect(server.isRunning)

        let engine = OpenAICompatibleEngine(baseURL: server.baseURL, model: "test", template: .generic)
        var tokens = 0
        for try await _ in engine.translate(.init(text: "Once upon a time", source: .code("en"), target: .code("en")!)) {
            tokens += 1
            if tokens >= 5 { break }
        }
        #expect(tokens > 0)

        server.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!server.isRunning)
    }
}
