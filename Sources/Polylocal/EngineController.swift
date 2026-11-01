import Engines
import Foundation
import ModelManager
import Observation
import PolylocalCore

/// Owns the active translation engine and its lifecycle (llama-server process or Ollama).
@MainActor
@Observable
final class EngineController {
    enum Status: Equatable {
        case notConfigured(String)
        case starting(String)
        case ready(String)
        case failed(String)

        var isReady: Bool { if case .ready = self { true } else { false } }

        var message: String {
            switch self {
            case .notConfigured(let m), .starting(let m), .ready(let m), .failed(let m): m
            }
        }
    }

    private(set) var status: Status = .notConfigured("Model seçilmedi")

    private var engine: (any TranslationEngine)?
    private var server: LlamaServer?
    private var configuredKey: String?
    private var configureTask: Task<Void, Never>?

    /// Starts (or switches to) the engine the settings point at. Safe to call repeatedly.
    func configure(settings: AppSettings, store: ModelStore) {
        let key: String
        switch settings.engineKind {
        case .builtIn: key = "builtIn:\(settings.builtInModelID ?? "-")"
        case .ollama: key = "ollama:\(settings.ollamaModel ?? "-")"
        }
        if key == configuredKey, status.isReady || configureTask != nil { return }
        configuredKey = key
        configureTask?.cancel()
        tearDown()

        switch settings.engineKind {
        case .builtIn:
            guard let id = settings.builtInModelID, let model = store.catalog.first(where: { $0.id == id }) else {
                status = .notConfigured("Model seçilmedi")
                return
            }
            guard store.state(of: model) == .installed else {
                status = .notConfigured("\(model.name) indirilmedi")
                return
            }
            let path = store.fileURL(for: model)
            status = .starting("\(model.name) yükleniyor…")
            configureTask = Task {
                defer { configureTask = nil }
                let server = LlamaServer(modelPath: path, pidFile: store.directory.appendingPathComponent("llama-server.pid"))
                do {
                    try await server.start()
                    try Task.checkCancellation()
                    self.server = server
                    let engine = OpenAICompatibleEngine(baseURL: server.baseURL, model: model.id, template: model.promptTemplate)
                    await warmUp(engine)
                    self.engine = engine
                    status = .ready("\(model.name) hazır")
                } catch is CancellationError {
                    server.stop()
                } catch {
                    server.stop()
                    status = .failed(error.localizedDescription)
                }
            }

        case .ollama:
            guard let name = settings.ollamaModel else {
                status = .notConfigured("Ollama modeli seçilmedi")
                return
            }
            status = .starting("Ollama: \(name) yükleniyor…")
            configureTask = Task {
                defer { configureTask = nil }
                guard let installed = await Ollama.installedModels() else {
                    status = .failed("Ollama çalışmıyor (localhost:11434)")
                    return
                }
                guard installed.contains(name) else {
                    status = .failed("Ollama'da \(name) yok")
                    return
                }
                let template: PromptTemplate = name.hasPrefix("translategemma") ? .translategemma : .generic
                let engine = OpenAICompatibleEngine(baseURL: Ollama.openAIBaseURL(), model: name, template: template)
                await warmUp(engine)
                guard !Task.isCancelled else { return }
                self.engine = engine
                status = .ready("Ollama: \(name) hazır")
            }
        }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        guard let engine, status.isReady else {
            let reason = status.message
            return AsyncThrowingStream { $0.finish(throwing: TranslationError.engineUnavailable(reason)) }
        }
        return engine.translate(request)
    }

    func shutdown() {
        configureTask?.cancel()
        tearDown()
    }

    private func tearDown() {
        server?.stop()
        server = nil
        engine = nil
    }

    /// Loads weights and fills the prompt cache so the first real request is fast (Faz 0: 1.1 s cold vs 0.4 s warm).
    private func warmUp(_ engine: any TranslationEngine) async {
        _ = try? await engine.translateAll(
            TranslationRequest(text: "Hello.", source: .code("en"), target: .code("tr")!))
    }
}
