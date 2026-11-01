import Foundation
import Observation
import TranslaterCore

enum EngineKind: String, CaseIterable, Identifiable {
    case builtIn, ollama
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var primaryLanguage: Language { didSet { save(primaryLanguage.code, "primaryLanguage") } }
    var secondaryLanguage: Language { didSet { save(secondaryLanguage.code, "secondaryLanguage") } }
    var engineKind: EngineKind { didSet { save(engineKind.rawValue, "engineKind") } }
    var builtInModelID: String? { didSet { save(builtInModelID, "builtInModelID") } }
    var ollamaModel: String? { didSet { save(ollamaModel, "ollamaModel") } }
    var hotkeysEnabled: Bool { didSet { save(hotkeysEnabled, "hotkeysEnabled") } }
    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    /// nil = shortcut turned off.
    var translateShortcut: Shortcut? { didSet { saveShortcut(translateShortcut, "translateShortcut") } }
    var replaceShortcut: Shortcut? { didSet { saveShortcut(replaceShortcut, "replaceShortcut") } }
    var defaultFormality: Formality { didSet { save(defaultFormality.rawValue, "defaultFormality") } }
    /// Off by default: translated text may be sensitive, so keeping it is the user's choice.
    var historyEnabled: Bool { didSet { save(historyEnabled, "historyEnabled") } }
    /// Inline suggestions only run in apps/sites that have a rule; this is the master switch.
    var inlineEnabled: Bool { didSet { save(inlineEnabled, "inlineEnabled") } }
    var inlineRules: [InlineRule] { didSet { defaults.set(try? JSONEncoder().encode(inlineRules), forKey: "inlineRules") } }
    var glossary: [GlossaryEntry] { didSet { defaults.set(try? JSONEncoder().encode(glossary), forKey: "glossary") } }
    /// nil = off. Opens the popup in rewrite (DeepL Write) mode instead of translating.
    var rewriteShortcut: Shortcut? { didSet { saveShortcut(rewriteShortcut, "rewriteShortcut") } }
    var defaultRewriteStyle: RewriteStyle { didSet { save(defaultRewriteStyle.rawValue, "defaultRewriteStyle") } }

    var pair: LanguagePair { LanguagePair(primary: primaryLanguage, secondary: secondaryLanguage) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
        let primaryDefault = Language.code(systemCode) ?? Language.code("en")!
        let secondaryDefault = primaryDefault.code == "en" ? Language.code("de")! : Language.code("en")!
        primaryLanguage = defaults.string(forKey: "primaryLanguage").flatMap(Language.code) ?? primaryDefault
        secondaryLanguage = defaults.string(forKey: "secondaryLanguage").flatMap(Language.code) ?? secondaryDefault
        engineKind = defaults.string(forKey: "engineKind").flatMap(EngineKind.init) ?? .builtIn
        builtInModelID = defaults.string(forKey: "builtInModelID")
        ollamaModel = defaults.string(forKey: "ollamaModel")
        hotkeysEnabled = defaults.object(forKey: "hotkeysEnabled") as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        translateShortcut = Self.loadShortcut(defaults, "translateShortcut", default: .defaultTranslate)
        replaceShortcut = Self.loadShortcut(defaults, "replaceShortcut", default: .defaultReplace)
        defaultFormality = defaults.string(forKey: "defaultFormality").flatMap(Formality.init) ?? .automatic
        historyEnabled = defaults.bool(forKey: "historyEnabled")
        inlineEnabled = defaults.object(forKey: "inlineEnabled") as? Bool ?? true
        inlineRules = defaults.data(forKey: "inlineRules").flatMap { try? JSONDecoder().decode([InlineRule].self, from: $0) } ?? []
        glossary = defaults.data(forKey: "glossary").flatMap { try? JSONDecoder().decode([GlossaryEntry].self, from: $0) } ?? []
        rewriteShortcut = Self.loadShortcut(defaults, "rewriteShortcut", default: nil)
        defaultRewriteStyle = defaults.string(forKey: "defaultRewriteStyle").flatMap(RewriteStyle.init) ?? .correct
    }

    private static func loadShortcut(_ defaults: UserDefaults, _ key: String, default value: Shortcut?) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return value }
        // Stored as JSON; an explicit `null` means the user turned the shortcut off.
        return try? JSONDecoder().decode(Shortcut?.self, from: data)
    }

    private func saveShortcut(_ shortcut: Shortcut?, _ key: String) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
