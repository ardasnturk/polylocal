import Foundation
import PolylocalCore

/// Streams chat completions from any OpenAI-compatible server (llama-server, Ollama, mlx_lm.server).
public struct OpenAICompatibleEngine: TranslationEngine {
    public var baseURL: URL
    public var model: String
    public var template: PromptTemplate

    public init(baseURL: URL, model: String, template: PromptTemplate) {
        self.baseURL = baseURL
        self.model = model
        self.template = template
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw TranslationError.server(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        switch SSEChunk.parse(line) {
                        case .token(let token): continuation.yield(token)
                        case .done: continuation.finish(); return
                        case .ignore: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequest(_ request: TranslationRequest) throws -> URLRequest {
        let maxTokens = switch request.kind {
        case .complete: 32
        case .summarize: 700
        case .alternatives: 200
        default: max(64, request.text.count * 2)
        }
        let body: [String: Any] = [
            "model": model,
            "messages": template.messages(for: request),
            "stream": true,
            "temperature": 0,
            "max_tokens": maxTokens,
            // Translation never needs a reasoning trace. Ollama reads the first, llama-server the second.
            "reasoning_effort": "none",
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        return urlRequest
    }
}

/// One line of an OpenAI-style server-sent event stream.
enum SSEChunk: Equatable {
    case token(String)
    case done
    case ignore

    static func parse(_ line: String) -> SSEChunk {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return .ignore }
        return .token(content)
    }
}
