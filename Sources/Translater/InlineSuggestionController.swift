import AppKit
import SystemIntegration
import TranslaterCore

/// Mode C: while the user types in an app/site with a rule, offer the paragraph in the rule's
/// language under the caret. Tab replaces, Esc dismisses, ⌥Tab inserts a real tab.
@MainActor
final class InlineSuggestionController {
    private unowned let app: AppModel
    private let watcher = FocusWatcher()
    private let panel = SuggestionPanel()

    private struct Pending {
        let field: FocusedField
        let segment: TextSegment
        let rule: InlineRule
        var translation = ""
        var isComplete = false
    }

    private var pending: Pending?
    private var task: Task<Void, Never>?
    /// Esc pauses suggestions in that field for a moment.
    private var pausedUntil: Date?
    /// Our own replacement fires a value change; ignore it.
    private var ignoreEditsUntil: Date?
    private(set) var isRunning = false

    static let debounce: Duration = .milliseconds(450)

    init(app: AppModel) {
        self.app = app
        watcher.shouldObserve = { [weak app] bundleID in
            guard let app, app.settings.inlineEnabled else { return false }
            return app.settings.inlineRules.contains { $0.isEnabled && $0.bundleID == bundleID }
        }
        watcher.onEvent = { [weak self] event in
            switch event {
            case .edited(let field): self?.fieldEdited(field)
            case .focusChanged: self?.dismiss()
            }
        }
    }

    /// Starts or stops watching to match settings and permissions. Call after any related change.
    func update(accessibilityTrusted: Bool) {
        let shouldRun = accessibilityTrusted && app.settings.inlineEnabled
            && app.settings.inlineRules.contains(where: \.isEnabled)
        if shouldRun, !isRunning {
            watcher.start()
            isRunning = true
        } else if !shouldRun, isRunning {
            watcher.stop()
            dismiss()
            isRunning = false
        }
    }

    /// Rules changed: re-check whether the frontmost app should be watched.
    func rulesChanged(accessibilityTrusted: Bool) {
        update(accessibilityTrusted: accessibilityTrusted)
        if isRunning { watcher.refresh() }
    }

    // MARK: Key handling (called from the event tap)

    func intercept(_ key: HotkeyMonitor.KeyPress) -> Bool {
        guard panel.isVisible, let pending else { return false }
        let tab: UInt16 = 48, esc: UInt16 = 53
        switch (key.keyCode, key.modifiers) {
        case (tab, []) where pending.isComplete:
            accept(pending)
            return true
        case (tab, .option):
            dismiss()
            HotkeyMonitor.postPlainTab()
            return true
        case (esc, []):
            dismiss()
            pausedUntil = Date().addingTimeInterval(4)
            return true
        default:
            // Any other key edits the text; the suggestion is stale.
            dismiss()
            return false
        }
    }

    // MARK: Flow

    private func fieldEdited(_ field: FocusedField) {
        task?.cancel()
        if panel.isVisible { dismiss() }
        if let ignoreEditsUntil, Date() < ignoreEditsUntil { return }
        if let pausedUntil, Date() < pausedUntil { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.evaluate(field)
        }
    }

    private func evaluate(_ field: FocusedField) async {
        guard app.engine.status.isReady, !field.isSecure, field.isEditableText,
              let text = field.text, let selection = field.selection, selection.length == 0 else { return }
        let rules = app.settings.inlineRules
        let host = InlineRules.hasSiteRules(rules, bundleID: field.bundleID) ? field.webHost : nil
        guard let rule = InlineRules.match(rules, bundleID: field.bundleID, host: host),
              let segment = TextSegmenter.paragraph(in: text, caretUTF16: selection.location) else { return }
        let detected = LanguageDetector.detect(segment.text,
                                               preferring: [app.settings.primaryLanguage, app.settings.secondaryLanguage])
        guard InlinePolicy.shouldSuggest(segment, target: rule.target, detected: detected),
              let caret = field.caretRect else { return }

        pending = Pending(field: field, segment: segment, rule: rule)
        panel.state.text = ""
        panel.state.isLoading = true
        panel.state.targetName = "\(detected?.localizedName ?? "?") → \(rule.target.localizedName)"
        panel.show(below: caret)

        let request = TranslationRequest(text: segment.text, source: detected, target: rule.target,
                                         formality: rule.formality)
        var output = ""
        do {
            for try await token in app.engine.translate(request) {
                if Task.isCancelled || pending == nil { return }
                output += token
                pending?.translation = output.trimmingCharacters(in: .whitespacesAndNewlines)
                panel.state.text = pending?.translation ?? ""
                panel.reposition(below: caret)
            }
        } catch {
            dismiss()
            return
        }
        guard !Task.isCancelled, pending != nil, !(pending?.translation.isEmpty ?? true) else {
            dismiss()
            return
        }
        pending?.isComplete = true
        panel.state.isLoading = false
        panel.reposition(below: caret)
        Log.capture.notice("inline suggest app=\(field.bundleID, privacy: .public) target=\(rule.target.code, privacy: .public)")
    }

    private func accept(_ suggestion: Pending) {
        dismiss()
        // The text must still be what we translated; otherwise the range points at something else.
        guard let text = suggestion.field.text,
              (text as NSString).length >= NSMaxRange(suggestion.segment.range),
              (text as NSString).substring(with: suggestion.segment.range) == suggestion.segment.text else { return }
        ignoreEditsUntil = Date().addingTimeInterval(1.5)
        Task {
            let result = await TextCapture.replace(range: suggestion.segment.range, in: suggestion.field,
                                                   with: suggestion.translation)
            Log.capture.notice("inline replace app=\(suggestion.field.bundleID, privacy: .public) via=\(result.rawValue, privacy: .public)")
            app.record(TranslationRequest(text: suggestion.segment.text, source: nil, target: suggestion.rule.target,
                                          formality: suggestion.rule.formality),
                       suggestion.translation, origin: .popup, appName: suggestion.field.appName)
        }
    }

    private func dismiss() {
        task?.cancel()
        task = nil
        pending = nil
        panel.hide()
    }
}
