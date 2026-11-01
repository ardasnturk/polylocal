import Foundation

public struct TranslationRequest: Sendable, Hashable {
    public var text: String
    public var source: Language?
    public var target: Language
    public var formality: Formality

    public init(text: String, source: Language?, target: Language, formality: Formality = .automatic) {
        self.text = text
        self.source = source
        self.target = target
        self.formality = formality
    }
}

/// Form of address (T–V distinction: siz/sen, Sie/du, vous/tu…).
public enum Formality: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, formal, informal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Otomatik"
        case .formal: "Resmi"
        case .informal: "Samimi"
        }
    }
}

extension Language {
    /// Languages with a grammatical formal/informal "you"; the option is hidden for the rest.
    public var hasFormality: Bool {
        ["tr", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "el", "az", "fa", "hi", "ja", "ko"].contains(code)
    }
}

public protocol TranslationEngine: Sendable {
    /// Streams the translation as it is generated. Cancelling the consuming task cancels generation.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

public extension TranslationEngine {
    func translateAll(_ request: TranslationRequest) async throws -> String {
        var output = ""
        for try await token in translate(request) { output += token }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How a model wants to be asked. Stored per model in the catalog.
public enum PromptTemplate: String, Codable, Sendable {
    case generic
    case translategemma

    public func messages(for request: TranslationRequest) -> [[String: String]] {
        let target = request.target.englishName
        switch self {
        case .generic:
            let from = request.source.map { " from \($0.englishName)" } ?? ""
            var system = """
            You are a professional translator. Translate the user's text\(from) to \(target). \
            Output only the translation. Preserve meaning, tone, numbers and formatting. \
            Do not add explanations, quotes or notes.
            """
            if request.target.hasFormality {
                switch request.formality {
                case .formal: system += " Address the reader formally (polite form of \"you\")."
                case .informal: system += " Address the reader informally (familiar form of \"you\")."
                case .automatic: break
                }
            }
            return [["role": "system", "content": system], ["role": "user", "content": request.text]]
        case .translategemma:
            // Prompt format from the TranslateGemma model card; it needs an explicit source language.
            let source = request.source ?? LanguageDetector.detect(request.text) ?? .init(code: "auto", englishName: "the source language")
            let s = source.englishName, sc = source.code, tc = request.target.code
            let prompt = """
            You are a professional \(s) (\(sc)) to \(target) (\(tc)) translator. \
            Your goal is to accurately convey the meaning and nuances of the original \(s) text \
            while adhering to \(target) grammar, vocabulary, and cultural sensitivities.
            Produce only the \(target) translation, without any additional explanations or commentary. \
            Please translate the following \(s) text into \(target):


            \(request.text)
            """
            return [["role": "user", "content": prompt]]
        }
    }
}

public enum TranslationError: LocalizedError, Sendable {
    case engineUnavailable(String)
    case server(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason): reason
        case .server(let status, let body): "Sunucu hatası \(status): \(body.prefix(200))"
        }
    }
}
