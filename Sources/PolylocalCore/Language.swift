import Foundation
import NaturalLanguage

public struct Language: Hashable, Codable, Sendable, Identifiable {
    public let code: String
    public let englishName: String

    public var id: String { code }

    /// Name in the app's UI language (not the region format locale), e.g. "German" / "Almanca".
    public var localizedName: String {
        let ui = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return ui.localizedString(forLanguageCode: code)?.localizedCapitalized ?? englishName
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
        // Unbiased first: hints act as priors and all but exclude other languages (German read as Turkish).
        if let best = bestHypothesis(text, hints: []), best.1 >= 0.5 || hints.isEmpty {
            return best.1 >= 0.35 ? best.0 : nil
        }
        // Short or ambiguous text: lean towards the user's pair.
        guard let best = bestHypothesis(text, hints: hints), best.1 >= 0.35 else { return nil }
        return best.0
    }

    private static func bestHypothesis(_ text: String, hints: [Language]) -> (Language, Double)? {
        let recognizer = NLLanguageRecognizer()
        if !hints.isEmpty {
            recognizer.languageHints = Dictionary(uniqueKeysWithValues: hints.map { (NLLanguage($0.code), 0.3) })
        }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 5)
            .compactMap { lang, p in Language.code(normalize(lang.rawValue)).map { ($0, p) } }
            .max { $0.1 < $1.1 }
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
