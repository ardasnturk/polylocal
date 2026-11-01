import AppKit
import SystemIntegration
import PolylocalCore

/// Mode C: while the user types in an app/site with a rule, offer the paragraph in the rule's
/// language under the caret, or (if the rule allows) a continuation when already writing in it.
/// Tab accepts, Esc dismisses, ⌥Tab inserts a real tab.
@MainActor
final class InlineSuggestionController {
    private unowned let app: AppModel
    private let watcher = FocusWatcher()
    private let panel = SuggestionPanel()

    private struct Pending {
        enum Kind { case translation, completion }

        let kind: Kind
        let field: FocusedField
        let rule: InlineRule
        /// Text that is replaced on accept (an empty range at the caret for completions).
        let replaceRange: NSRange
        /// Must still be in the field at `checkRange` when accepting; otherwise the text moved on.
        let checkRange: NSRange
        let checkText: String
        let sourceText: String
        var suggestion = ""
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
        let ns = text as NSString
        let caret = selection.location

        let candidate: Pending
        let request: TranslationRequest
        if InlinePolicy.shouldSuggest(segment, target: rule.target, detected: detected) {
            candidate = Pending(kind: .translation, field: field, rule: rule, replaceRange: segment.range,
                                checkRange: segment.range, checkText: segment.text, sourceText: segment.text)
            request = TranslationRequest(text: segment.text, source: detected, target: rule.target, formality: rule.formality,
                                         glossary: Glossary.relevant(app.settings.glossary, for: segment.text, target: rule.target))
            panel.state.targetName = "\(detected?.localizedName ?? "?") → \(rule.target.localizedName)"
        } else if rule.completions {
            let lineEnd = ns.lineRange(for: NSRange(location: caret, length: 0))
            let rest = ns.substring(with: NSRange(location: caret, length: max(0, NSMaxRange(lineEnd) - caret)))
            let prefix = ns.substring(with: NSRange(location: segment.range.location,
                                                    length: max(0, caret - segment.range.location)))
            guard InlinePolicy.shouldComplete(prefix: prefix, rest: rest, target: rule.target, detected: detected)
            else { return }
            // Up to ~600 characters of context before the caret.
            let contextStart = max(0, caret - 600)
            let context = ns.substring(with: NSRange(location: contextStart, length: caret - contextStart))
            let checkStart = max(0, caret - 40)
            let checkRange = NSRange(location: checkStart, length: caret - checkStart)
            candidate = Pending(kind: .completion, field: field, rule: rule,
                                replaceRange: NSRange(location: caret, length: 0),
                                checkRange: checkRange, checkText: ns.substring(with: checkRange), sourceText: context)
            request = TranslationRequest(text: context, source: rule.target, target: rule.target, kind: .complete)
            panel.state.targetName = String(localized: "Completion · \(rule.target.localizedName)")
        } else {
            return
        }
        guard let caretRect = field.caretRect else { return }

        pending = candidate
        panel.state.text = ""
        panel.state.isLoading = true
        if candidate.kind == .translation { panel.show(below: caretRect) }

        var output = ""
        do {
            for try await token in app.engine.translate(request) {
                if Task.isCancelled || pending == nil { return }
                output += token
                if candidate.kind == .translation {
                    pending?.suggestion = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    panel.state.text = pending?.suggestion ?? ""
                    panel.reposition(below: caretRect)
                }
            }
        } catch {
            dismiss()
            return
        }
        guard !Task.isCancelled, pending != nil else { return }
        if candidate.kind == .completion {
            // Shown only once complete: partial continuations flicker and get cleaned up anyway.
            guard let cleaned = InlinePolicy.completionText(output, after: candidate.sourceText) else {
                dismiss()
                return
            }
            pending?.suggestion = cleaned
            panel.state.text = "…" + cleaned
            panel.show(below: caretRect)
        }
        guard !(pending?.suggestion.isEmpty ?? true) else {
            dismiss()
            return
        }
        pending?.isComplete = true
        panel.state.isLoading = false
        panel.reposition(below: caretRect)
        Log.capture.notice("inline \(candidate.kind == .translation ? "suggest" : "complete", privacy: .public) app=\(field.bundleID, privacy: .public) target=\(rule.target.code, privacy: .public)")
    }

    private func accept(_ suggestion: Pending) {
        dismiss()
        // The text must still be what we looked at; otherwise the range points at something else.
        guard let text = suggestion.field.text,
              (text as NSString).length >= NSMaxRange(suggestion.checkRange),
              (text as NSString).substring(with: suggestion.checkRange) == suggestion.checkText else { return }
        ignoreEditsUntil = Date().addingTimeInterval(1.5)
        Task {
            let result = await TextCapture.replace(range: suggestion.replaceRange, in: suggestion.field,
                                                   with: suggestion.suggestion)
            Log.capture.notice("inline accept app=\(suggestion.field.bundleID, privacy: .public) via=\(result.rawValue, privacy: .public)")
            if suggestion.kind == .translation {
                app.record(TranslationRequest(text: suggestion.sourceText, source: nil, target: suggestion.rule.target,
                                              formality: suggestion.rule.formality),
                           suggestion.suggestion, origin: .popup, appName: suggestion.field.appName)
            }
        }
    }

    private func dismiss() {
        task?.cancel()
        task = nil
        pending = nil
        panel.hide()
    }
}
