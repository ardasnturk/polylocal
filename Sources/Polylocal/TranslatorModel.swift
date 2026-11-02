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
    /// Remembered per target language (Settings), so "du" for German stays "du" next time.
    var formality: Formality {
        get { settings.formality(for: target) }
        set {
            guard newValue != formality else { return }
            settings.formalityByLanguage[target.code] = newValue
            scheduleTranslation(immediately: true)
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case translate, rewrite
        var id: String { rawValue }
        var title: String { self == .translate ? String(localized: "Translate") : String(localized: "Write") }
    }

    var mode: Mode = .translate { didSet { if mode != oldValue { scheduleTranslation(immediately: true) } } }
    var rewriteStyle: RewriteStyle { didSet { if rewriteStyle != oldValue { scheduleTranslation(immediately: true) } } }

    private(set) var output = ""
    /// Word choices made in this translation ("toplantıya" → "Treffen"); kept while the text still contains the term.
    private(set) var chosenTerms: [GlossaryEntry] = []
    private(set) var detectedSource: Language?
    private(set) var isTranslating = false
    private(set) var error: String?

    var debounce: Duration = .milliseconds(450)
    /// Called with each finished translation (used for history).
    @ObservationIgnored var onComplete: ((TranslationRequest, String) -> Void)?

    private let settings: AppSettings
    private let engine: EngineController
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var readyObserver: NSObjectProtocol?

    deinit {
        if let readyObserver { NotificationCenter.default.removeObserver(readyObserver) }
    }

    init(settings: AppSettings, engine: EngineController) {
        self.settings = settings
        self.engine = engine
        rewriteStyle = settings.defaultRewriteStyle
        readyObserver = NotificationCenter.default.addObserver(forName: .engineDidBecomeReady, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.error != nil else { return }
                self.retry()
            }
        }
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
        chosenTerms = []
        output = ""
        error = nil
        input = text
        scheduleTranslation(immediately: true)
    }

    func retry() { scheduleTranslation(immediately: true) }

    /// Other ways to say `span` (a word or phrase of the current translation), and the source words it translates.
    func alternatives(for span: String) async throws -> WordAlternatives {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TranslationRequest(text: text, source: source, target: target,
                                         kind: .alternatives(span: span, translation: output))
        var reply = ""
        for try await token in engine.translate(request) { reply += token }
        guard let parsed = WordAlternatives.parse(reply, span: span, sourceText: text) else {
            throw TranslationError.engineUnavailable(String(localized: "The model did not suggest alternatives."))
        }
        return parsed
    }

    /// Uses `alternative` instead of `span` and rebuilds the sentence around it. With the source words known, the
    /// choice becomes a term for this text (and, if `remember`, a glossary entry); otherwise the translation is
    /// kept up to the span and continued from the alternative.
    func choose(_ alternative: String, for span: String, at range: NSRange, source term: String?, remember: Bool) {
        if let term {
            let entry = GlossaryEntry(source: term, target: alternative, targetLanguage: target)
            chosenTerms.removeAll { $0.source.caseInsensitiveCompare(term) == .orderedSame && $0.targetLanguage == target }
            chosenTerms.append(entry)
            if remember {
                settings.glossary.removeAll { $0.source.caseInsensitiveCompare(term) == .orderedSame && $0.targetLanguage == target }
                settings.glossary.append(entry)
            }
            scheduleTranslation(immediately: true)
        } else if let range = Range(range, in: output) {
            let prefix = String(output[..<range.lowerBound]) + alternative
            scheduleTranslation(immediately: true, prefix: prefix)
        }
    }

    private func scheduleTranslation(immediately: Bool = false, prefix: String? = nil) {
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
            await self.run(text, prefix: prefix)
        }
    }

    private func run(_ text: String, prefix: String? = nil) async {
        detectedSource = LanguageDetector.detect(text, preferring: [settings.primaryLanguage, settings.secondaryLanguage])
        let request: TranslationRequest
        switch mode {
        case .translate:
            // Choices made in this text win over the saved glossary.
            let chosen = Glossary.relevant(chosenTerms, for: text, target: target)
            let saved = Glossary.relevant(settings.glossary, for: text, target: target).filter { entry in
                !chosen.contains { $0.source.caseInsensitiveCompare(entry.source) == .orderedSame }
            }
            request = TranslationRequest(text: text, source: source, target: target, formality: formality,
                                         glossary: saved + chosen, prefix: prefix)
        case .rewrite:
            // Rewrite stays in the text's own language.
            let language = source ?? settings.primaryLanguage
            request = TranslationRequest(text: text, source: language, target: language, kind: .rewrite(rewriteStyle))
        }
        isTranslating = true
        error = nil
        var buffer = request.prefix ?? ""
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
