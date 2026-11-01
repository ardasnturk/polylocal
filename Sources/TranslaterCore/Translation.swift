import Foundation

public struct TranslationRequest: Sendable, Hashable {
    /// What the model is asked to do with `text`. For `.rewrite` and `.complete`, `target` is the text's own language.
    public enum Kind: Hashable, Sendable {
        case translate
        case rewrite(RewriteStyle)
        case complete
    }

    public var text: String
    public var source: Language?
    public var target: Language
    public var formality: Formality
    public var kind: Kind
    /// Terms that must be translated a fixed way; pass only entries relevant to `text`.
    public var glossary: [GlossaryEntry]

    public init(text: String, source: Language?, target: Language, formality: Formality = .automatic,
                kind: Kind = .translate, glossary: [GlossaryEntry] = []) {
        self.text = text
        self.source = source
        self.target = target
        self.formality = formality
        self.kind = kind
        self.glossary = glossary
    }
}

/// DeepL Write-style rewrites, in the text's own language.
public enum RewriteStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case correct, fluent, formal, casual, concise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .correct: "Düzelt"
        case .fluent: "Akıcı"
        case .formal: "Resmi"
        case .casual: "Samimi"
        case .concise: "Kısa"
        }
    }

    var instruction: String {
        switch self {
        case .correct: "Fix only spelling, grammar and punctuation. Keep the wording, tone and meaning otherwise unchanged."
        case .fluent: "Make it read naturally and fluently, as a native speaker would write it. Keep the meaning and tone."
        case .formal: "Make it polite and professional, suitable for business communication. Keep the meaning."
        case .casual: "Make it friendly and casual, as in a chat with a colleague. Keep the meaning."
        case .concise: "Make it shorter and clearer. Remove filler but keep every important point."
        }
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
        // Rewrite and completion do not depend on the model's translation format.
        switch request.kind {
        case .rewrite(let style): return Prompts.rewrite(request, style: style)
        case .complete: return Prompts.complete(request)
        case .translate: break
        }
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
            if !request.glossary.isEmpty {
                let terms = request.glossary.map { "\"\($0.source)\" → \"\($0.target)\"" }.joined(separator: "; ")
                system += " Always use these term translations: \(terms)."
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

enum Prompts {
    static func rewrite(_ request: TranslationRequest, style: RewriteStyle) -> [[String: String]] {
        let language = request.target.englishName
        let system = """
        You are an expert \(language) editor. Rewrite the user's text in \(language). \(style.instruction) \
        Output only the rewritten text, without quotes, explanations or notes.
        """
        return [["role": "system", "content": system], ["role": "user", "content": request.text]]
    }

    static func complete(_ request: TranslationRequest) -> [[String: String]] {
        let language = request.target.englishName
        let system = """
        You are an autocomplete engine for \(language). Continue the user's unfinished text with the most likely \
        next words, at most one short sentence, ending where the current sentence ends. \
        Output only the continuation. Never repeat the user's text, never add quotes or explanations.
        """
        return [["role": "system", "content": system], ["role": "user", "content": request.text]]
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
