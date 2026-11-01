import Foundation

/// Minimal Ollama client: lets users who already run Ollama reuse their models instead of downloading again.
public enum Ollama {
    public static let defaultURL = URL(string: "http://localhost:11434")!

    public static func openAIBaseURL(_ root: URL = defaultURL) -> URL {
        root.appendingPathComponent("v1")
    }

    /// Installed model names, or nil when Ollama is not running.
    public static func installedModels(at root: URL = defaultURL) async -> [String]? {
        var request = URLRequest(url: root.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
