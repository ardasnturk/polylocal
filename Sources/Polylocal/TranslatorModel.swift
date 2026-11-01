import Foundation
import Observation
import PolylocalCore

/// State of one translation surface (the popup or the main window): input, direction, streamed output.
@MainActor
@Observable
final class TranslatorModel {
    var input = "" { didSet { if input != oldValue { scheduleTranslation() } } }
    /// nil = detect automatically.
    var sourceOverride: Language? { didSet { scheduleTranslation(immediately: true) } }
    /// nil = derive from the language pair.
    var targetOverride: Language? { didSet { scheduleTranslation(immediately: true) } }
    var formality: Formality { didSet { if formality != oldValue { scheduleTranslation(immediately: true) } } }

    enum Mode: String, CaseIterable, Identifiable {
        case translate, rewrite
        var id: String { rawValue }
        var title: String { self == .translate ? String(localized: "Translate") : String(localized: "Write") }
    }

    var mode: Mode = .translate { didSet { if mode != oldValue { scheduleTranslation(immediately: true) } } }
    var rewriteStyle: RewriteStyle { didSet { if rewriteStyle != oldValue { scheduleTranslation(immediately: true) } } }

    private(set) var output = ""
    private(set) var detectedSource: Language?
    private(set) var isTranslating = false
    private(set) var error: String?

    var debounce: Duration = .milliseconds(450)
    /// Called with each finished translation (used for history).
    @ObservationIgnored var onComplete: ((TranslationRequest, String) -> Void)?

    private let settings: AppSettings
    private let engine: EngineController
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings, engine: EngineController) {
        self.settings = settings
        self.engine = engine
        formality = settings.defaultFormality
        rewriteStyle = settings.defaultRewriteStyle
    }

    var source: Language? { sourceOverride ?? detectedSource }

    var target: Language {
        targetOverride ?? settings.pair.target(forSource: source)
    }

    func swap() {
        let newSource = target
        let newTarget = source ?? settings.pair.secondary
        sourceOverride = newSource
        targetOverride = newTarget
        if !output.isEmpty { input = output }
    }

    func reset(input text: String) {
        task?.cancel()
        sourceOverride = nil
        targetOverride = nil
        formality = settings.defaultFormality
        output = ""
        error = nil
        input = text
        scheduleTranslation(immediately: true)
    }

    func retry() { scheduleTranslation(immediately: true) }

    private func scheduleTranslation(immediately: Bool = false) {
        task?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            detectedSource = nil
            isTranslating = false
            error = nil
            return
        }
        let delay = immediately ? .zero : debounce
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            await self.run(text)
        }
    }

    private func run(_ text: String) async {
        detectedSource = LanguageDetector.detect(text, preferring: [settings.primaryLanguage, settings.secondaryLanguage])
        let request: TranslationRequest
        switch mode {
        case .translate:
            request = TranslationRequest(text: text, source: source, target: target, formality: formality,
                                         glossary: Glossary.relevant(settings.glossary, for: text, target: target))
        case .rewrite:
            // Rewrite stays in the text's own language.
            let language = source ?? settings.primaryLanguage
            request = TranslationRequest(text: text, source: language, target: language, kind: .rewrite(rewriteStyle))
        }
        isTranslating = true
        error = nil
        var buffer = ""
        defer { if !Task.isCancelled { isTranslating = false } }
        do {
            for try await token in engine.translate(request) {
                if Task.isCancelled { return }
                buffer += token
                output = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !Task.isCancelled, !output.isEmpty { onComplete?(request, output) }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
