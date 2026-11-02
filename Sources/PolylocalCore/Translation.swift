import Foundation

public struct TranslationRequest: Sendable, Hashable {
    /// What the model is asked to do with `text`. For `.rewrite` and `.complete`, `target` is the text's own language.
    public enum Kind: Hashable, Sendable {
        case translate
        case rewrite(RewriteStyle)
        case complete
        /// Meeting notes: summarize a transcript (or partial summaries of one) in `target`.
        case summarize
        /// Other ways to say `span`, a part of `translation` (the translation of `text`). Answer: WordAlternatives JSON.
        case alternatives(span: String, translation: String)
    }

    public var text: String
    public var source: Language?
    public var target: Language
    public var formality: Formality
    public var kind: Kind
    /// Terms that must be translated a fixed way; pass only entries relevant to `text`.
    public var glossary: [GlossaryEntry]
    /// For `.translate`: the translation must start with this; the model only writes the rest.
    public var prefix: String?

    public init(text: String, source: Language?, target: Language, formality: Formality = .automatic,
                kind: Kind = .translate, glossary: [GlossaryEntry] = [], prefix: String? = nil) {
        self.text = text
        self.source = source
        self.target = target
        self.formality = formality
        self.kind = kind
        self.glossary = glossary
        self.prefix = prefix
    }
}

/// DeepL Write-style rewrites, in the text's own language.
public enum RewriteStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case correct, fluent, formal, casual, concise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .correct: String(localized: "Correct")
        case .fluent: String(localized: "Fluent")
        case .formal: String(localized: "Formal")
        case .casual: String(localized: "Casual")
        case .concise: String(localized: "Concise")
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
        case .automatic: String(localized: "Automatic")
        case .formal: String(localized: "Formal")
        case .informal: String(localized: "Informal")
        }
    }
}

extension Language {
    /// Languages with a grammatical formal/informal "you"; the option is hidden for the rest.
    public var hasFormality: Bool {
        ["tr", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "el", "az", "fa", "hi", "ja", "ko"].contains(code)
    }

    /// The formal and informal "you" as speakers of the language name them, for a compact switch (Sie | du).
    public var formalityWords: (formal: String, informal: String)? {
        switch code {
        case "de": ("Sie", "du")
        case "tr", "az": ("siz", "sen")
        case "fr": ("vous", "tu")
        case "es": ("usted", "tú")
        case "it": ("Lei", "tu")
        case "pt": ("o senhor", "você")
        case "nl": ("u", "jij")
        case "pl": ("Pan/Pani", "ty")
        case "ru": ("вы", "ты")
        case "uk": ("ви", "ти")
        case "el": ("εσείς", "εσύ")
        default: nil
        }
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
        case .summarize: return Prompts.summarize(request)
        case .alternatives(let span, let translation): return Prompts.alternatives(request, span: span, translation: translation)
        case .translate: break
        }
        var messages = translationMessages(for: request)
        // Prefill: llama-server and Ollama continue a final assistant message instead of starting a new one.
        if let prefix = request.prefix, !prefix.isEmpty {
            messages.append(["role": "assistant", "content": prefix])
        }
        return messages
    }

    private func translationMessages(for request: TranslationRequest) -> [[String: String]] {
        let target = request.target.englishName
        switch self {
        case .generic:
            let from = request.source.map { " from \($0.englishName)" } ?? ""
            var system = """
            You are a professional translator. Translate the user's text\(from) to \(target). \
            Output only the translation. Preserve meaning, tone, numbers and formatting. \
            Do not add explanations, quotes or notes.
            """
            system += Prompts.constraints(request)
            return [["role": "system", "content": system], ["role": "user", "content": request.text]]
        case .translategemma:
            // Prompt format from the TranslateGemma model card; it needs an explicit source language.
            let source = request.source ?? LanguageDetector.detect(request.text) ?? .init(code: "auto", englishName: "the source language")
            let s = source.englishName, sc = source.code, tc = request.target.code
            let prompt = """
            You are a professional \(s) (\(sc)) to \(target) (\(tc)) translator. \
            Your goal is to accurately convey the meaning and nuances of the original \(s) text \
            while adhering to \(target) grammar, vocabulary, and cultural sensitivities.
            Produce only the \(target) translation, without any additional explanations or commentary.\(Prompts.constraints(request)) \
            Please translate the following \(s) text into \(target):


            \(request.text)
            """
            return [["role": "user", "content": prompt]]
        }
    }
}

enum Prompts {
    /// Form of address and glossary terms, as sentences appended to a translation instruction ("" if none).
    static func constraints(_ request: TranslationRequest) -> String {
        var text = ""
        if request.target.hasFormality {
            let words = request.target.formalityWords
            switch request.formality {
            case .formal: text += " Address the reader formally (polite form of \"you\"\(words.map { ", \($0.formal)" } ?? ""))."
            case .informal: text += " Address the reader informally (familiar form of \"you\"\(words.map { ", \($0.informal)" } ?? ""))."
            case .automatic: break
            }
        }
        if !request.glossary.isEmpty {
            let terms = request.glossary.map { "\"\($0.source)\" → \"\($0.target)\"" }.joined(separator: "; ")
            text += " Always use these term translations, adapting the surrounding grammar: \(terms)."
        }
        return text
    }

    static func alternatives(_ request: TranslationRequest, span: String, translation: String) -> [[String: String]] {
        let source = request.source?.englishName ?? "Original"
        let target = request.target.englishName
        // Naming the key after the source language ("turkish") makes small models copy source words into it;
        // with a generic "source" key they tended to repeat the marked target word.
        let system = """
        You help a user choose words in a \(source) to \(target) translation. One part of the \(target) translation \
        is marked as [[...]]. Reply with JSON only: {"alternatives": [up to 5 other \(target) words or phrases that \
        could replace the marked part in this sentence, best first], "\(source.lowercased())": "the matching words \
        copied from the \(source) text"}
        """
        let marked: String
        if let range = translation.range(of: span) {
            marked = translation.replacingCharacters(in: range, with: "[[\(span)]]")
        } else {
            marked = translation + " [[\(span)]]"
        }
        let user = "\(source): \(request.text)\n\(target): \(marked)"
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    static func rewrite(_ request: TranslationRequest, style: RewriteStyle) -> [[String: String]] {
        let language = request.target.englishName
        let system = """
        You are an expert \(language) editor. Rewrite the user's text in \(language). \(style.instruction) \
        Output only the rewritten text, without quotes, explanations or notes.
        """
        return [["role": "system", "content": system], ["role": "user", "content": request.text]]
    }

    static func summarize(_ request: TranslationRequest) -> [[String: String]] {
        let language = request.target.englishName
        let system = """
        You write meeting notes. The user's text is a meeting transcript produced by speech recognition, or \
        notes on consecutive parts of one meeting. Write in \(language), in Markdown, with exactly these four \
        sections as level-2 headings translated into \(language): Summary (2–4 sentences), Decisions, \
        Action items (who does what, if said), Open questions. Use bullet points under the last three and write \
        "—" when a section has nothing. Only use what is in the text; recognition errors may occur, so skip \
        anything that does not make sense. Output only the notes.
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

/// The answer to a `.alternatives` request.
public struct WordAlternatives: Sendable, Hashable {
    /// The part of the source text the span translates; nil if the model named something not in the text.
    public var source: String?
    public var alternatives: [String]

    public init(source: String?, alternatives: [String]) {
        self.source = source
        self.alternatives = alternatives
    }

    /// Parses the model's JSON (tolerating code fences or text around it). Drops alternatives equal to `span`,
    /// duplicates, and source words that do not occur in `sourceText`.
    public static func parse(_ reply: String, span: String, sourceText: String) -> WordAlternatives? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
        else { return nil }
        var seen: Set<String> = [span.lowercased()]
        let alternatives = (object["alternatives"] as? [Any] ?? []).compactMap { item -> String? in
            guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
        // The source words come under the source language's name ("turkish"), or any other string key.
        var source = object.first { $0.key != "alternatives" && $0.value is String }
            .flatMap { ($0.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let found = source, found.isEmpty || sourceText.range(of: found, options: .caseInsensitive) == nil {
            source = nil
        }
        return WordAlternatives(source: source, alternatives: Array(alternatives.prefix(5)))
    }
}

public enum TranslationError: LocalizedError, Sendable {
    case engineUnavailable(String)
    case server(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason): reason
        case .server(let status, let body): String(localized: "Server error \(status): \(String(body.prefix(200)))")
        }
    }
}
