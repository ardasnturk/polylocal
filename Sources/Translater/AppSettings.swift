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
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
