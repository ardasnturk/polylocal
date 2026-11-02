import AppKit
import Engines
import ModelManager
import Observation
import SystemIntegration
import PolylocalCore

/// Wires the pieces together: settings → engine, shortcuts → capture → popup.
@MainActor
@Observable
final class AppModel {
    static let shared: AppModel = {
        Migration.run()
        return AppModel()
    }()

    let settings = AppSettings()
    let store = ModelStore(catalog: ModelStore.bundledCatalog())
    let engine = EngineController()
    let history = HistoryStore()
    let updater = Updater()
    let microphoneDriver = MicrophoneDriver()
    var settingsTab: SettingsTab = .general
    let mainTranslator: TranslatorModel
    /// The quick translate field in the menu bar panel.
    let quickTranslator: TranslatorModel
    private(set) var accessibilityTrusted = Permissions.isAccessibilityTrusted
    private(set) var ollamaModels: [String]?

    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private(set) lazy var popup = PopupController(app: self)
    @ObservationIgnored private(set) lazy var windows = WindowManager(app: self)
    @ObservationIgnored private(set) lazy var inline = InlineSuggestionController(app: self)
    @ObservationIgnored private(set) lazy var meeting = MeetingController(app: self)
    @ObservationIgnored private var permissionTimer: Timer?

    private init() {
        mainTranslator = TranslatorModel(settings: settings, engine: engine)
        quickTranslator = TranslatorModel(settings: settings, engine: engine)
        mainTranslator.onComplete = { [weak self] request, output in
            self?.record(request, output, origin: .window, appName: nil)
        }
        quickTranslator.onComplete = { [weak self] request, output in
            self?.record(request, output, origin: .window, appName: nil)
        }
    }

    private(set) var hotkeysRunning = false

    var hotkeysActive: Bool { hotkeysRunning && settings.hotkeysEnabled }

    func start() {
        hotkeys.onTrigger = { [weak self] trigger in
            Task { await self?.handle(trigger) }
        }
        hotkeys.interceptor = { [weak self] key in
            self?.inline.intercept(key) ?? false
        }
        applyShortcuts()
        watchAccessibility()
        meeting.watchMicrophone()
        Task {
            await refreshOllama()
            chooseDefaultEngineIfNeeded()
            applyEngine()
            if needsSetup { windows.showOnboarding() }
            // Development aid: start meeting mode for an app without the menu, e.g. for end-to-end tests.
            if let source = ProcessInfo.processInfo.environment["POLYLOCAL_MEETING_SOURCE"] {
                let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == source }?.localizedName
                meeting.start(MeetingApp(bundleID: source, name: name ?? source))
            }
            // Development aid: open the translation window with a text, e.g. for UI checks.
            if let text = ProcessInfo.processInfo.environment["POLYLOCAL_TRANSLATE"] {
                windows.showMain(with: text)
            }
            if ProcessInfo.processInfo.environment["POLYLOCAL_PANEL_WINDOW"] != nil {
                windows.showMenuBarPanelPreview()
            }
        }
    }

    /// The setup assistant opens on launch until it was finished once *and* the app can actually work:
    /// a reinstall over stale settings, a revoked permission or a deleted model brings it back.
    var needsSetup: Bool {
        Self.needsSetup(completedOnboarding: settings.hasCompletedOnboarding, accessibilityTrusted: accessibilityTrusted,
                        hasUsableModel: hasUsableModel)
    }

    nonisolated static func needsSetup(completedOnboarding: Bool, accessibilityTrusted: Bool, hasUsableModel: Bool) -> Bool {
        !completedOnboarding || !accessibilityTrusted || !hasUsableModel
    }

    private var hasUsableModel: Bool {
        switch settings.engineKind {
        case .builtIn:
            store.installedModels.contains { $0.id == settings.builtInModelID }
        case .ollama:
            settings.ollamaModel.map { ollamaModels?.contains($0) ?? false } ?? false
        }
    }

    func shutdown() {
        meeting.stop()
        engine.shutdown()
    }

    func applyEngine() {
        engine.configure(settings: settings, store: store)
    }

    func applyShortcuts() {
        var shortcuts: [HotkeyMonitor.Action: Shortcut] = [:]
        shortcuts[.translate] = settings.translateShortcut
        shortcuts[.replace] = settings.replaceShortcut
        shortcuts[.rewrite] = settings.rewriteShortcut
        hotkeys.setShortcuts(shortcuts)
    }

    func applyInlineRules() {
        inline.rulesChanged(accessibilityTrusted: accessibilityTrusted)
    }

    /// While recording a new shortcut in Settings, the old one must not fire.
    func setShortcutRecording(_ recording: Bool) {
        hotkeys.isPaused = recording
    }

    func record(_ request: TranslationRequest, _ output: String, origin: HistoryStore.Entry.Origin, appName: String?) {
        guard settings.historyEnabled else { return }
        history.add(.init(date: Date(), sourceText: request.text, translation: output, source: request.source,
                          target: request.target, origin: origin, appName: appName))
    }

    func refreshOllama() async {
        ollamaModels = await Ollama.installedModels()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    /// First launch: prefer an already-installed built-in model, then an Ollama model, so it works without a download.
    private func chooseDefaultEngineIfNeeded() {
        guard settings.builtInModelID == nil, settings.ollamaModel == nil else { return }
        if let installed = store.installedModels(.translation).first {
            settings.engineKind = .builtIn
            settings.builtInModelID = installed.id
        } else if let models = ollamaModels, let pick = Self.preferredOllamaModel(models) {
            settings.engineKind = .ollama
            settings.ollamaModel = pick
        } else {
            settings.engineKind = .builtIn
            settings.builtInModelID = CatalogModel.recommended(from: store.catalog, ramGB: Hardware.memoryGB)?.id
        }
    }

    static func preferredOllamaModel(_ models: [String]) -> String? {
        models.first { $0.hasPrefix("gemma4") } ?? models.first { $0.hasPrefix("translategemma") } ?? models.first
    }

    private func watchAccessibility() {
        checkAccessibility()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
    }

    private func checkAccessibility() {
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        if accessibilityTrusted, !hotkeys.isRunning { hotkeys.start() }
        hotkeysRunning = hotkeys.isRunning
        inline.update(accessibilityTrusted: accessibilityTrusted)
    }

    private func handle(_ trigger: HotkeyMonitor.Trigger) async {
        guard settings.hotkeysEnabled else { return }
        // ⌘C+C inside our own windows is just copying.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        guard let captured = await TextCapture.captureSelection(
            pasteboardChangeCount: trigger.pasteboardChangeCount,
            // Only a ⌘C-based shortcut has already copied the selection; any other needs a simulated copy.
            allowSimulatedCopy: !trigger.shortcut.copiesSelection)
        else {
            Log.capture.notice("capture app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public) action=\(String(describing: trigger.action), privacy: .public) result=none")
            NSSound.beep()
            return
        }
        // Never log the text itself.
        Log.capture.notice("""
            capture app=\(captured.bundleID ?? "?", privacy: .public) action=\(String(describing: trigger.action), privacy: .public) \
            via=\(captured.source.rawValue, privacy: .public) role=\(captured.role ?? "-", privacy: .public) \
            replaceable=\(captured.isReplaceable, privacy: .public) rect=\(captured.selectionRect != nil, privacy: .public)
            """)
        popup.show(captured, action: trigger.action)
    }
}
