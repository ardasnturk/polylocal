import Foundation
import NaturalLanguage

public struct Language: Hashable, Codable, Sendable, Identifiable {
    public let code: String
    public let englishName: String

    public var id: String { code }

    public var localizedName: String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? englishName
    }

    public init(code: String, englishName: String) {
        self.code = code
        self.englishName = englishName
    }

    /// Languages the default models handle well. Order is the order shown in pickers.
    public static let all: [Language] = [
        .init(code: "tr", englishName: "Turkish"),
        .init(code: "en", englishName: "English"),
        .init(code: "de", englishName: "German"),
        .init(code: "fr", englishName: "French"),
        .init(code: "es", englishName: "Spanish"),
        .init(code: "it", englishName: "Italian"),
        .init(code: "pt", englishName: "Portuguese"),
        .init(code: "nl", englishName: "Dutch"),
        .init(code: "pl", englishName: "Polish"),
        .init(code: "ru", englishName: "Russian"),
        .init(code: "uk", englishName: "Ukrainian"),
        .init(code: "ar", englishName: "Arabic"),
        .init(code: "fa", englishName: "Persian"),
        .init(code: "zh", englishName: "Chinese"),
        .init(code: "ja", englishName: "Japanese"),
        .init(code: "ko", englishName: "Korean"),
        .init(code: "hi", englishName: "Hindi"),
        .init(code: "sv", englishName: "Swedish"),
        .init(code: "el", englishName: "Greek"),
        .init(code: "az", englishName: "Azerbaijani"),
    ]

    public static func code(_ code: String) -> Language? {
        all.first { $0.code == code }
    }
}

public enum LanguageDetector {
    /// Most likely supported language for `text`, or nil when the text is too short or ambiguous.
    public static func detect(_ text: String, preferring hints: [Language] = []) -> Language? {
        let recognizer = NLLanguageRecognizer()
        if !hints.isEmpty {
            // Mild bias towards the user's pair; short texts are otherwise easily misread.
            recognizer.languageHints = Dictionary(uniqueKeysWithValues: hints.map { (NLLanguage($0.code), 0.3) })
        }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let best = hypotheses
            .compactMap { lang, p in Language.code(normalize(lang.rawValue)).map { ($0, p) } }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= 0.35 else { return nil }
        return best.0
    }

    private static func normalize(_ code: String) -> String {
        // NaturalLanguage reports zh-Hans / zh-Hant; we only care about the base language.
        String(code.prefix { $0 != "-" })
    }
}

/// The user's language pair: text in `primary` goes to `secondary`, everything else goes to `primary`.
public struct LanguagePair: Codable, Hashable, Sendable {
    public var primary: Language
    public var secondary: Language

    public init(primary: Language, secondary: Language) {
        self.primary = primary
        self.secondary = secondary
    }

    public func target(forSource source: Language?) -> Language {
        source == primary ? secondary : primary
    }
}
